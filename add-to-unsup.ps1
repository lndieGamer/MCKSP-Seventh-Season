<#
    add-to-unsup.ps1 — галочки в unsup: добавить, переименовать,
    перепривязать, удалить.

    Работает с unsup.toml поблочно: файл режется по заголовкам таблиц, и
    правится ровно нужный блок. Комментарии, стоящие ПЕРЕД заголовком,
    относятся к предыдущему блоку и не трогаются — так безопаснее.
    Перед каждой записью создаётся unsup.toml.bak.

    Запуск из корня пака (или откуда угодно с -PackDir):
        .\add-to-unsup.ps1              меню действий
        .\add-to-unsup.ps1 sodium       сразу найти мод для добавления
        .\add-to-unsup.ps1 -List        клиентские моды без галочки
        .\add-to-unsup.ps1 -Edit        сразу к правке существующих
        .\add-to-unsup.ps1 -DryRun      ничего не писать, только показать
#>

param(
    [Parameter(Position = 0)]
    [string]$Query,
    [string]$PackDir,
    [switch]$List,
    [switch]$Edit,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Read-Host в PowerShell 5.1 при chcp 65001 возвращает «?» вместо кириллицы,
# пока консоли не задана кодировка явно.
try {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    [Console]::InputEncoding  = New-Object Text.UTF8Encoding $false
} catch { }

# Add-Content в Windows PowerShell 5.1 пишет в системной ANSI-кодировке, а не
# в UTF-8: если она не кириллическая, весь текст превращается в «?». Именно
# так испортились названия галочек. Пишем байты сами.
# Get-Content в PowerShell 5.1 читает файл без BOM в системной ANSI-кодировке.
# UTF-8 при этом превращается в мусор, и если такой текст записать обратно —
# получится двойная перекодировка (Ã¢â‚¬ вместо кириллицы). Читаем явно.
function Read-Utf8($path) {
    [IO.File]::ReadAllText((Resolve-Path $path).Path,
        (New-Object Text.UTF8Encoding $false))
}

function Append-Utf8($path, $text) {
    if (-not (Test-Path $path)) { New-Item $path -ItemType File -Force | Out-Null }
    [IO.File]::AppendAllText(
        (Resolve-Path $path).Path, $text, (New-Object Text.UTF8Encoding $false))
}
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
$toml = Read-Utf8 'unsup.toml'

# ---------- метафайлы ----------
function Read-Mods {
    $r = @()
    foreach ($f in Get-ChildItem 'mods\*.pw.toml' -EA SilentlyContinue) {
        $t = Read-Utf8 $f.FullName
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

# ---------- работа с unsup.toml поблочно ----------
# Блок = строка-заголовок таблицы и всё до следующего заголовка. То, что
# стоит до первого заголовка, идёт отдельным куском без имени.
function Split-Toml($text) {
    $blocks = @()
    $cur = [pscustomobject]@{ Header = $null; Lines = @() }
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*\[\[?([^\]]+)\]\]?\s*$') {
            $blocks += $cur
            $cur = [pscustomobject]@{ Header = $Matches[1]; Lines = @($line) }
        } else {
            $cur.Lines += $line
        }
    }
    $blocks += $cur
    $blocks
}

function Join-Toml($blocks) {
    (($blocks | ForEach-Object { $_.Lines -join "`n" }) -join "`n")
}

function Save-Toml($blocks) {
    $text = Join-Toml $blocks
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    if ($DryRun) { Say "  сухой прогон — unsup.toml не тронут" Magenta; return }
    Copy-Item 'unsup.toml' 'unsup.toml.bak' -Force
    [IO.File]::WriteAllText((Resolve-Path 'unsup.toml').Path, $text,
        (New-Object Text.UTF8Encoding $false))
    Say "  записано, копия старого файла — unsup.toml.bak" Green
}

# заголовки у нас двух видов: с кавычками и без
function Header-Is($block, $prefix, $id) {
    if (-not $block.Header) { return $false }
    $h = $block.Header
    ($h -eq "$prefix.`"$id`"") -or ($h -eq "$prefix.$id")
}

function Is-Bound($id) {
    ($toml -match [regex]::Escape("[metafile.`"$id`"]")) -or ($toml -match [regex]::Escape("[metafile.$id]"))
}

$mods    = Read-Mods
$unbound = @($mods | Where-Object { $_.Side -eq 'client' -and -not (Is-Bound $_.Id) } | Sort-Object Id)

if ($List) {
    if ($unbound.Count -eq 0) {
        Say "Все клиентские моды уже привязаны к галочкам." Green
    } else {
        Head "Клиентские моды без галочки: $($unbound.Count)"
        Say "  Такие ставятся всем и всегда." DarkGray
        $unbound | ForEach-Object { Say ("  {0,-34} {1}" -f $_.Id, (Plain $_.Name)) }
    }
    exit 0
}

# ---------- список существующих галочек ----------
function Get-Groups($blocks) {
    $r = @()
    foreach ($b in $blocks) {
        if (-not $b.Header) { continue }
        if ($b.Header -notmatch '^flavor_groups\.(.+)$') { continue }
        $id = $Matches[1].Trim('"')
        if ($id -like '*.choices') { continue }
        $nm = ''
        foreach ($l in $b.Lines) { if ($l -match '^\s*name\s*=\s*"(.*)"') { $nm = $Matches[1]; break } }
        $r += [pscustomobject]@{ Id = $id; Name = $nm; Block = $b }
    }
    $r
}

function Pick-Group($groups, $title) {
    Head $title
    for ($i = 0; $i -lt $groups.Count; $i++) {
        Say ("  {0,2}) {1,-30} {2}" -f ($i+1), $groups[$i].Id, (Plain $groups[$i].Name))
    }
    $p = Read-Host "`nНомер (Enter — отмена)"
    if (-not $p) { return $null }
    $gi = 0
    if (-not [int]::TryParse($p, [ref]$gi) -or $gi -lt 1 -or $gi -gt $groups.Count) {
        Say "Неверный номер." Red; return $null
    }
    $groups[$gi-1]
}

function Do-Rename {
    $blocks = Split-Toml (Read-Utf8 'unsup.toml')
    $groups = @(Get-Groups $blocks)
    if ($groups.Count -eq 0) { Say "В unsup.toml нет галочек." Yellow; return }
    $g = Pick-Group $groups "Какую галочку правим"
    if (-not $g) { return }

    $curName = $g.Name
    $curDesc = ''
    foreach ($l in $g.Block.Lines) { if ($l -match '^\s*description\s*=\s*"(.*)"') { $curDesc = $Matches[1] } }

    Head "$(Plain $curName)"
    Say "  описание: $curDesc" DarkGray
    Say ""
    $nm = Read-Host "  Новое название (Enter — оставить)"
    $ds = Read-Host "  Новое описание (Enter — оставить)"
    if (-not $nm -and -not $ds) { Say "Ничего не меняли." Yellow; return }

    $newLines = @()
    foreach ($l in $g.Block.Lines) {
        if ($nm -and $l -match '^\s*name\s*=\s*"') {
            $newLines += 'name = "' + ($nm -replace '"', "'") + '"'
        } elseif ($ds -and $l -match '^\s*description\s*=\s*"') {
            $newLines += 'description = "' + ($ds -replace '"', "'") + '"'
        } else { $newLines += $l }
    }
    $g.Block.Lines = $newLines

    Head "Запись"
    Save-Toml $blocks
}

function Do-Rebind {
    $blocks = Split-Toml (Read-Utf8 'unsup.toml')
    $binds = @()
    foreach ($b in $blocks) {
        if ($b.Header -and $b.Header -match '^metafile\.(.+)$') {
            $id = $Matches[1].Trim('"')
            $fl = ''
            foreach ($l in $b.Lines) { if ($l -match '^\s*flavors\s*=\s*(.*)$') { $fl = $Matches[1] } }
            $binds += [pscustomobject]@{ Id = $id; Name = $fl; Block = $b }
        }
    }
    if ($binds.Count -eq 0) { Say "В unsup.toml нет привязок." Yellow; return }
    $b = Pick-Group $binds "Какую привязку правим"
    if (-not $b) { return }

    $groups = @(Get-Groups $blocks)
    Head "Галочки, к которым можно привязать"
    for ($i = 0; $i -lt $groups.Count; $i++) {
        Say ("  {0,2}) {1}" -f ($i+1), (Plain $groups[$i].Name))
    }
    Say ""
    Say "  Через запятую, если нужно несколько: мод встанет, если включена" DarkGray
    Say "  хотя бы одна из них. Так привязывают библиотеки." DarkGray
    $p = Read-Host "`nНомера (Enter — отмена)"
    if (-not $p) { return }

    $ids = @()
    foreach ($n in ($p -split '[,\s]+' | Where-Object { $_ })) {
        $gi = 0
        if (-not [int]::TryParse($n, [ref]$gi) -or $gi -lt 1 -or $gi -gt $groups.Count) {
            Say "  неверный номер: $n" Red; return
        }
        $ids += $groups[$gi-1].Id + '_on'
    }

    $newLines = @()
    foreach ($l in $b.Block.Lines) {
        if ($l -match '^\s*flavors\s*=') {
            $newLines += 'flavors = [' + (($ids | ForEach-Object { "`"$_`"" }) -join ', ') + ']'
        } else { $newLines += $l }
    }
    $b.Block.Lines = $newLines
    Say "  новая привязка: $($ids -join ', ')" DarkGray

    Head "Запись"
    Save-Toml $blocks
}

function Do-Remove {
    $blocks = Split-Toml (Read-Utf8 'unsup.toml')
    $groups = @(Get-Groups $blocks)
    if ($groups.Count -eq 0) { Say "В unsup.toml нет галочек." Yellow; return }
    $g = Pick-Group $groups "Какую галочку удаляем"
    if (-not $g) { return }

    # на выборы этой галочки могут ссылаться привязки других модов
    $refs = @()
    foreach ($b in $blocks) {
        if (-not $b.Header -or $b.Header -notmatch '^metafile\.(.+)$') { continue }
        $who = $Matches[1].Trim('"')
        if ($who -eq $g.Id) { continue }
        foreach ($l in $b.Lines) {
            if ($l -match '^\s*flavors\s*=' -and $l -like "*$($g.Id)_on*") { $refs += $who }
        }
    }
    if ($refs.Count -gt 0) {
        Head "Осторожно"
        Say "  На «$($g.Id)_on» ссылаются привязки: $($refs -join ', ')" Red
        Say "  После удаления они будут указывать в пустоту, и эти моды" Yellow
        Say "  перестанут ставиться. Сначала перепривяжите их." Yellow
        $go = Read-Host "  Всё равно удалить? (введите ДА)"
        if ($go -ne 'ДА') { Say "  Отменено." Yellow; return }
    }

    $kept = @()
    $dropped = 0
    foreach ($b in $blocks) {
        $drop = $false
        if ($b.Header) {
            if ($b.Header -eq "flavor_groups.`"$($g.Id)`"" -or $b.Header -eq "flavor_groups.$($g.Id)") { $drop = $true }
            if ($b.Header -like "flavor_groups.`"$($g.Id)`".choices" -or $b.Header -like "flavor_groups.$($g.Id).choices") { $drop = $true }
            if (Header-Is $b 'metafile' $g.Id) { $drop = $true }
        }
        if ($drop) { $dropped++ } else { $kept += $b }
    }

    Head "Удаление"
    Say "  убрано блоков: $dropped" DarkGray
    Say "  мод $($g.Id) снова будет ставиться всем и всегда" Yellow
    Save-Toml $kept
}

# ---------- меню действий ----------
if ($Edit -or (-not $Query -and -not $List)) {
    Head "Что делаем"
    Say "  1) добавить галочку"
    Say "  2) переименовать / изменить описание"
    Say "  3) изменить привязку мода к галочкам"
    Say "  4) удалить галочку"
    $act = Read-Host "`nВариант [1]"
    if (-not $act) { $act = '1' }
    switch ($act) {
        '2' { Do-Rename; exit 0 }
        '3' { Do-Rebind; exit 0 }
        '4' { Do-Remove; exit 0 }
        '1' { }
        default { Say "Отменено." Yellow; exit 0 }
    }
}

# ---------- выбираем мод (ветка добавления) ----------
if ($unbound.Count -eq 0) {
    Say ""
    Say "Все клиентские моды уже привязаны к галочкам — добавлять нечего." Green
    Say "Для правки существующих запустите с -Edit." DarkGray
    exit 0
}

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
Append-Utf8 'unsup.toml' $add
Say "  готово, копия старого файла — unsup.toml.bak" Green

Head "Дальше"
Say "  packwiz refresh"
Say "  git add -A && git commit && git push"
Say ""
Say "  У тех, кто уже играет, новая галочка появится в окне unsup" DarkGray
Say "  при следующем запуске игры — ответа на неё в их состоянии нет." DarkGray
