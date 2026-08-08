<#
    add-to-unsup.ps1 — завести галочку в unsup для клиентского мода.

    Показывает клиентские моды, которых нет в unsup.toml (такие ставятся всем
    и всегда), и добавляет для выбранного либо свою галочку, либо привязку к
    уже существующей.

    Запуск из корня пака (или откуда угодно с -PackDir):
        .\add-to-unsup.ps1              список и выбор
        .\add-to-unsup.ps1 sodium       сразу найти мод
        .\add-to-unsup.ps1 -List        только показать непривязанные
        .\add-to-unsup.ps1 sodium -DryRun
#>

param(
    [Parameter(Position = 0)]
    [string]$Query,
    [string]$PackDir,
    [switch]$List,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$UA = @{ 'User-Agent' = 'mckspack-helper/1.0 (private modpack)' }

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Plain($t) { ($t -replace '[\uD800-\uDFFF]', '').Trim() }

# ---------- где лежит пак ----------
function Find-PackRoot([string[]]$starts) {
    foreach ($start in $starts) {
        if (-not $start) { continue }
        $d = Get-Item -LiteralPath $start -EA SilentlyContinue
        while ($d) {
            if (Test-Path (Join-Path $d.FullName 'pack.toml')) { return $d.FullName }
            $d = $d.Parent
        }
    }
    $null
}

if ($PackDir) {
    if (-not (Test-Path (Join-Path $PackDir 'pack.toml'))) {
        Say "В указанной папке нет pack.toml: $PackDir" Red; exit 1
    }
    $root = (Resolve-Path $PackDir).Path
} else {
    $root = Find-PackRoot @($PSScriptRoot, (Get-Location).Path)
    if (-not $root) {
        Say "pack.toml не найден. Укажите папку явно: -PackDir C:\путь\к\паку" Red; exit 1
    }
}
Set-Location $root

if (-not (Test-Path 'unsup.toml')) {
    Say "unsup.toml не найден рядом с pack.toml." Red; exit 1
}
$toml = Get-Content 'unsup.toml' -Raw

# ---------- метафайлы ----------
function Read-Mods {
    $r = @()
    foreach ($f in Get-ChildItem 'mods\*.pw.toml' -EA SilentlyContinue) {
        $t = Get-Content $f.FullName -Raw
        $r += [pscustomobject]@{
            Id   = $f.BaseName -replace '\.pw$', ''
            Name = if ($t -match '(?m)^name\s*=\s*"(.*)"')        { $Matches[1] } else { $f.BaseName }
            Side = if ($t -match '(?m)^side\s*=\s*"(.*)"')        { $Matches[1] } else { 'both' }
            Hash = if ($t -match '(?m)^hash\s*=\s*"(.*)"')        { $Matches[1].ToLower() } else { '' }
            HFmt = if ($t -match '(?m)^hash-format\s*=\s*"(.*)"') { $Matches[1] } else { '' }
        }
    }
    $r
}

function Is-Bound($id) {
    ($toml -match [regex]::Escape("[metafile.`"$id`"]")) -or ($toml -match [regex]::Escape("[metafile.$id]"))
}

$mods    = Read-Mods
$unbound = @($mods | Where-Object { $_.Side -eq 'client' -and -not (Is-Bound $_.Id) } | Sort-Object Id)

if ($unbound.Count -eq 0) {
    Say "Все клиентские моды уже привязаны к галочкам." Green
    exit 0
}

if ($List) {
    Head "Клиентские моды без галочки: $($unbound.Count)"
    Say "  Такие ставятся всем и всегда." DarkGray
    $unbound | ForEach-Object { Say ("  {0,-34} {1}" -f $_.Id, (Plain $_.Name)) }
    exit 0
}

# ---------- выбираем мод ----------
if ($Query) {
    $hits = @($unbound | Where-Object { $_.Id -like "*$Query*" -or $_.Name -like "*$Query*" })
    if ($hits.Count -eq 0) {
        Say "Среди непривязанных клиентских модов нет совпадений по '$Query'." Yellow
        Say "Посмотреть весь список: -List" DarkGray
        exit 1
    }
} else {
    $hits = $unbound
}

if ($hits.Count -gt 1) {
    Head "Клиентские моды без галочки: $($hits.Count)"
    for ($i = 0; $i -lt $hits.Count; $i++) {
        Say ("  {0,2}) {1,-34} {2}" -f ($i+1), $hits[$i].Id, (Plain $hits[$i].Name))
    }
    $pick = Read-Host "`nНомер (Enter — отмена)"
    if (-not $pick) { exit 0 }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $hits.Count) {
        Say "Неверный номер." Red; exit 1
    }
    $mod = $hits[$idx-1]
} else {
    $mod = $hits[0]
}

Head "$(Plain $mod.Name)"
Say "  метафайл: $($mod.Id)"

# ---------- кто от него зависит ----------
function Get-Dependents($modId, $all) {
    $hashes = @{}
    foreach ($m in $all) {
        if (-not $m.Hash -or -not $m.HFmt) { continue }
        if (-not $hashes.ContainsKey($m.HFmt)) { $hashes[$m.HFmt] = @() }
        $hashes[$m.HFmt] += $m.Hash
    }
    $vers = @{}
    foreach ($algo in $hashes.Keys) {
        try {
            $body = @{ hashes = $hashes[$algo]; algorithm = $algo } | ConvertTo-Json -Compress
            $r = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' `
                    -ContentType 'application/json' -Headers $UA `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body))
            foreach ($pr in $r.PSObject.Properties) { $vers[$pr.Name.ToLower()] = $pr.Value }
        } catch { }
    }
    $me = $null
    foreach ($m in $all) { if ($m.Id -eq $modId -and $vers[$m.Hash]) { $me = $vers[$m.Hash] } }
    if (-not $me) { return @() }
    $out = @()
    foreach ($m in $all) {
        $v = $vers[$m.Hash]
        if (-not $v -or $m.Id -eq $modId) { continue }
        foreach ($d in $v.dependencies) {
            if ($d.dependency_type -eq 'required' -and $d.project_id -eq $me.project_id) { $out += $m }
        }
    }
    $out
}

Say "  смотрю зависимости..." DarkGray
$dependents = @(Get-Dependents $mod.Id $mods)

# существующие галочки — для варианта «привязать к чужой»
$groups = @()
foreach ($m in [regex]::Matches($toml, '(?m)^\[flavor_groups\."?([^\]"]+)"?\]')) {
    $gid = $m.Groups[1].Value
    $nm  = ''
    $after = $toml.Substring($m.Index)
    if ($after -match '(?m)^name\s*=\s*"(.*)"') { $nm = $Matches[1] }
    $groups += [pscustomobject]@{ Id = $gid; Name = $nm }
}

if ($dependents.Count -gt 0) {
    Say ""
    Say "  От этого мода зависят: $((($dependents | ForEach-Object { $_.Id }) -join ', '))" Yellow
    Say "  Это библиотека. Своя галочка ей обычно не нужна — если её" Yellow
    Say "  отключить, зависимые моды упадут. Правильнее привязать её к" Yellow
    Say "  галочкам потребителей: тогда она ставится, пока включён хотя" Yellow
    Say "  бы один из них." Yellow
}

# ---------- что делаем ----------
Say ""
Say "  1) своя галочка"
if ($dependents.Count -gt 0) {
    Say "  2) привязать к галочкам тех, кому мод нужен (рекомендуется)"
}
Say "  3) привязать к существующей галочке (выберу из списка)"
$mode = Read-Host "`nВариант (Enter — отмена)"

$add = ''

switch ($mode) {

    '1' {
        $label = Read-Host "    Название галочки [$(Plain $mod.Name)]"
        if (-not $label) { $label = Plain $mod.Name }
        $desc = Read-Host "    Короткое описание"
        $label = $label -replace '"', "'"
        $desc  = $desc  -replace '"', "'"
        $add = @"

[flavor_groups."$($mod.Id)"]
name = "$label"
description = "$desc"
side = "client"

[[flavor_groups."$($mod.Id)".choices]]
id = "$($mod.Id)_on"
name = "Включить"

[[flavor_groups."$($mod.Id)".choices]]
id = "$($mod.Id)_off"
name = "Отключить"

[metafile."$($mod.Id)"]
flavors = ["$($mod.Id)_on"]
"@
    }

    '2' {
        if ($dependents.Count -eq 0) { Say "Этот вариант тут не подходит." Yellow; exit 1 }
        $fl = @()
        foreach ($d in $dependents) {
            if ($toml -match [regex]::Escape("[flavor_groups.`"$($d.Id)`"]")) {
                $fl += "$($d.Id)_on"
            } else {
                Say "    у $($d.Id) нет своей галочки — пропускаю" Yellow
            }
        }
        if ($fl.Count -eq 0) {
            Say "  Ни у одного потребителя нет галочки. Заведите её сначала им." Red
            exit 1
        }
        $add = @"

[metafile."$($mod.Id)"]
flavors = [$(($fl | ForEach-Object { "`"$_`"" }) -join ', ')]
"@
        Say "    привяжу к: $($fl -join ', ')" DarkGray
    }

    '3' {
        if ($groups.Count -eq 0) { Say "  В unsup.toml нет ни одной галочки." Red; exit 1 }
        Head "Существующие галочки"
        for ($i = 0; $i -lt $groups.Count; $i++) {
            Say ("  {0,2}) {1}" -f ($i+1), (Plain $groups[$i].Name))
        }
        $p = Read-Host "`nНомер (Enter — отмена)"
        if (-not $p) { exit 0 }
        $gi = 0
        if (-not [int]::TryParse($p, [ref]$gi) -or $gi -lt 1 -or $gi -gt $groups.Count) {
            Say "Неверный номер." Red; exit 1
        }
        $gid = $groups[$gi-1].Id
        $add = @"

[metafile."$($mod.Id)"]
flavors = ["${gid}_on"]
"@
        Say "    привяжу к галочке: $gid" DarkGray
    }

    default { Say "Отменено." Yellow; exit 0 }
}

# ---------- запись ----------
Head "Запись в unsup.toml"
if ($DryRun) {
    Say "  сухой прогон, будет добавлено:" Magenta
    $add -split "`n" | ForEach-Object { Say "  $_" DarkGray }
    exit 0
}

Copy-Item 'unsup.toml' 'unsup.toml.bak' -Force
Add-Content 'unsup.toml' $add
Say "  готово, копия старого файла — unsup.toml.bak" Green

Head "Дальше"
Say "  packwiz refresh"
Say "  git add -A && git commit && git push"
Say ""
Say "  У тех, кто уже играет, новая галочка появится в окне unsup" DarkGray
Say "  при следующем запуске игры — ответа на неё в их состоянии нет." DarkGray
