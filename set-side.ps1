<#
    set-side.ps1 — сменить сторону (side) у мода.

    Ищет мод по части названия или имени метафайла, показывает совпадения,
    меняет side и разбирается с последствиями: галочка в unsup.toml,
    сетевые каналы, зависимости.

    В отличие от set-sides.ps1, который расставляет стороны всему паку по
    зашитому списку, этот работает точечно и задаёт вопросы.

    Запуск из корня пака (или откуда угодно, если указать -PackDir):
        .\set-side.ps1 sodium              найти и сменить
        .\set-side.ps1 sodium -To both     сразу указать сторону
        .\set-side.ps1 -List               показать текущую раскладку
        .\set-side.ps1 sodium -DryRun      только показать, что будет
#>

param(
    [Parameter(Position = 0)]
    [string]$Query,
    [ValidateSet('client', 'server', 'both')]
    [string]$To,
    [string]$PackDir,
    [switch]$List,
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
# Нативные программы пишут в stderr и при успехе: git — строки вида
# "From https://...", packwiz — прогресс. При $ErrorActionPreference = 'Stop'
# конструкция 2>&1 превращает такую строку в терминирующую ошибку
# NativeCommandError и роняет скрипт на ровном месте. Поэтому на время вызова
# снимаем Stop и приводим вывод к обычным строкам.
function Run-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(ValueFromRemainingArguments)][string[]]$Arguments
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1 | ForEach-Object { [string]$_ }
    } finally { $ErrorActionPreference = $prev }
    ,@($out)
}

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

# ---------- читаем метафайлы ----------
function Read-Mods {
    $r = @()
    foreach ($f in Get-ChildItem 'mods\*.pw.toml' -EA SilentlyContinue) {
        $t = Read-Utf8 $f.FullName
        $r += [pscustomobject]@{
            Id   = $f.BaseName -replace '\.pw$', ''
            Path = $f.FullName
            Name = if ($t -match '(?m)^name\s*=\s*"(.*)"')        { $Matches[1] } else { $f.BaseName }
            Side = if ($t -match '(?m)^side\s*=\s*"(.*)"')        { $Matches[1] } else { 'both' }
            Hash = if ($t -match '(?m)^hash\s*=\s*"(.*)"')        { $Matches[1].ToLower() } else { '' }
            HFmt = if ($t -match '(?m)^hash-format\s*=\s*"(.*)"') { $Matches[1] } else { '' }
        }
    }
    $r
}

$mods = Read-Mods
if ($mods.Count -eq 0) { Say "В mods\ нет метафайлов." Red; exit 1 }

if ($List) {
    foreach ($grp in ($mods | Group-Object Side | Sort-Object Name)) {
        Head "$($grp.Name) — $($grp.Count)"
        $grp.Group | Sort-Object Id | ForEach-Object {
            Say ("  {0,-34} {1}" -f $_.Id, (Plain $_.Name))
        }
    }
    exit 0
}

if (-not $Query) {
    $Query = Read-Host "Название мода или часть имени метафайла"
    if (-not $Query) { Say "Ничего не введено." Yellow; exit 0 }
}

# ---------- ищем ----------
$hits = @($mods | Where-Object { $_.Id -like "*$Query*" -or $_.Name -like "*$Query*" })

if ($hits.Count -eq 0) { Say "Ничего не найдено по запросу '$Query'." Yellow; exit 1 }

if ($hits.Count -gt 1) {
    Head "Найдено: $($hits.Count)"
    for ($i = 0; $i -lt $hits.Count; $i++) {
        Say ("  {0,2}) {1,-34} {2,-7} {3}" -f ($i+1), $hits[$i].Id, $hits[$i].Side, (Plain $hits[$i].Name))
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
Say "  сторона:  $($mod.Side)"

# ---------- что известно про мод ----------
$mrVersion = $null
if ($mod.Hash -and $mod.HFmt) {
    try {
        $body = @{ hashes = @($mod.Hash); algorithm = $mod.HFmt } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' `
                -ContentType 'application/json' -Headers $UA `
                -Body ([Text.Encoding]::UTF8.GetBytes($body))
        foreach ($pr in $r.PSObject.Properties) { $mrVersion = $pr.Value }
    } catch { }
}

# кто зависит от этого мода — такие моды нельзя оставлять без него
function Get-Dependents($modId) {
    $all = Read-Mods
    $hashes = @{ sha1 = @(); sha512 = @(); sha256 = @() }
    foreach ($m in $all) { if ($m.Hash -and $hashes.ContainsKey($m.HFmt)) { $hashes[$m.HFmt] += $m.Hash } }
    $vers = @{}
    foreach ($algo in $hashes.Keys) {
        if ($hashes[$algo].Count -eq 0) { continue }
        try {
            $body = @{ hashes = $hashes[$algo]; algorithm = $algo } | ConvertTo-Json -Compress
            $r = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' `
                    -ContentType 'application/json' -Headers $UA `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body))
            foreach ($pr in $r.PSObject.Properties) { $vers[$pr.Name.ToLower()] = $pr.Value }
        } catch { }
    }
    $pid2id = @{}
    foreach ($m in $all) { if ($vers[$m.Hash]) { $pid2id[$vers[$m.Hash].project_id] = $m } }
    $me = $null
    foreach ($m in $all) { if ($m.Id -eq $modId -and $vers[$m.Hash]) { $me = $vers[$m.Hash] } }
    if (-not $me) { return @() }

    $out = @()
    foreach ($m in $all) {
        $v = $vers[$m.Hash]
        if (-not $v) { continue }
        foreach ($d in $v.dependencies) {
            if ($d.dependency_type -ne 'required') { continue }
            if ($d.project_id -eq $me.project_id) { $out += $m }
        }
    }
    $out
}

# ---------- выбор новой стороны ----------
if (-not $To) {
    Say ""
    Say "  1) client — только клиент"
    Say "  2) server — только сервер"
    Say "  3) both   — обе стороны"
    $c = Read-Host "`nНовая сторона (Enter — отмена)"
    switch ($c) {
        '1' { $To = 'client' }
        '2' { $To = 'server' }
        '3' { $To = 'both' }
        default { Say "Отменено." Yellow; exit 0 }
    }
}

# Сторона может уже быть нужной — но галочки при этом может не быть.
# Ради неё одной и заходят чаще всего, поэтому не выходим сразу.
$sideChanged = $true
if ($To -eq $mod.Side) {
    $sideChanged = $false
    Say ""
    Say "  Сторона уже $To — менять её не нужно." Yellow

    $bound = $false
    if (Test-Path 'unsup.toml') {
        $tmpToml = Read-Utf8 'unsup.toml'
        $bound = ($tmpToml -match [regex]::Escape("[metafile.`"$($mod.Id)`"]")) -or
                 ($tmpToml -match [regex]::Escape("[metafile.$($mod.Id)]"))
    }

    if ($To -ne 'client' -or $bound) { exit 0 }
    Say "  Но галочки в unsup.toml у него нет — предложу завести." DarkGray
}

# ---------- предупреждения ----------
if ($sideChanged) {
Head "Проверки"

$dependents = @(Get-Dependents $mod.Id)
if ($dependents.Count -gt 0) {
    Say "  от этого мода зависят: $((($dependents | ForEach-Object { $_.Id }) -join ', '))" DarkGray
    if ($To -eq 'client') {
        $srv = @($dependents | Where-Object { $_.Side -ne 'client' })
        if ($srv.Count -gt 0) {
            Say ""
            Say "  НЕЛЬЗЯ: от мода зависят серверные моды" Red
            $srv | ForEach-Object { Say "    $($_.Id) (side = $($_.Side))" Yellow }
            Say "  Сделав его клиентским, вы уроните сервер при загрузке." Yellow
            exit 1
        }
    }
}

if ($To -eq 'client' -and $mrVersion) {
    Say "  качаю jar, проверяю сетевые каналы..." DarkGray
    try {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mck-" + [guid]::NewGuid().ToString('N') + ".jar")
        Invoke-WebRequest -Uri $mrVersion.files[0].url -OutFile $tmp -Headers $UA -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($tmp)
        $net = $false; $opt = $false
        foreach ($e in $zip.Entries) {
            if (-not $e.FullName.EndsWith('.class')) { continue }
            $sr = New-Object IO.StreamReader($e.Open())
            $txt = $sr.ReadToEnd(); $sr.Close()
            if ($txt -like '*PayloadRegistrar*') {
                $net = $true
                if ($txt -like '*optional*') { $opt = $true }
                break
            }
        }
        $zip.Dispose(); Remove-Item $tmp -Force -EA SilentlyContinue

        if ($net -and -not $opt) {
            Say ""
            Say "  ОПАСНО: мод регистрирует сетевой канал без .optional()" Red
            Say "  Клиент потребует канал, которого не будет на сервере," Yellow
            Say "  и подключение отвалится. Именно так вёл себя Coastal Waves." Yellow
            $go = Read-Host "  Всё равно продолжить? (введите ДА)"
            if ($go -ne 'ДА') { Say "  Отменено." Yellow; exit 0 }
        } elseif ($net) {
            Say "  сетевой канал есть, но помечен как optional — безопасно" Green
        } else {
            Say "  сетевых каналов не найдено" Green
        }
    } catch {
        Say "  проверить jar не удалось: $($_.Exception.Message)" Yellow
    }
}

# ---------- пишем side ----------
Head "Смена стороны: $($mod.Side) -> $To"

$t = Read-Utf8 $mod.Path
if ($t -match '(?m)^side\s*=\s*".+?"') {
    $t = [regex]::Replace($t, '(?m)^side\s*=\s*".+?"', "side = `"$To`"", 1)
} else {
    $t = [regex]::Replace($t, '(?m)^(filename\s*=\s*".+?")', "`$1`nside = `"$To`"", 1)
}

if ($DryRun) {
    Say "  сухой прогон — файл не тронут" Magenta
} else {
    [IO.File]::WriteAllText($mod.Path, $t, (New-Object Text.UTF8Encoding $false))
    Say "  $($mod.Id).pw.toml обновлён" Green
}
}

# ---------- галочка в unsup.toml ----------
if (Test-Path 'unsup.toml') {
    $toml = Read-Utf8 'unsup.toml'
    $hasGroup = $toml -match [regex]::Escape("[flavor_groups.`"$($mod.Id)`"]")
    $hasBind  = $toml -match [regex]::Escape("[metafile.`"$($mod.Id)`"]")

    if ($To -ne 'client' -and ($hasGroup -or $hasBind)) {
        Head "Галочка в unsup.toml"
        Say "  У мода есть галочка, но он больше не клиентский." Yellow
        Say "  Отключаемый мод на сервере — это рассинхрон по сетевым каналам." Yellow
        Say "  Уберите вручную из unsup.toml:" Yellow
        if ($hasGroup) { Say "    [flavor_groups.`"$($mod.Id)`"] со всеми choices" DarkGray }
        if ($hasBind)  { Say "    [metafile.`"$($mod.Id)`"]" DarkGray }
        Say "  И проверьте, не ссылается ли на «$($mod.Id)_on» какая-нибудь библиотека." DarkGray
    }

    if ($To -eq 'client' -and -not $hasBind) {
        Head "Галочка в unsup.toml"
        Say "  Мод стал клиентским, но галочки у него нет — значит будет" DarkGray
        Say "  ставиться всем и всегда. Завести галочку?" DarkGray
        $label = Read-Host "    Название (Enter — не заводить)"
        if ($label) {
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
            if ($DryRun) { Say "    сухой прогон — unsup.toml не тронут" Magenta }
            else { Append-Utf8 'unsup.toml' $add; Say "    галочка добавлена" Green }
        }
    }
}

# ---------- что дальше ----------
Head "Дальше"
if ($DryRun) {
    Say "  Сухой прогон. Ничего не записано." Magenta
    exit 0
}
Say "  packwiz refresh"
Say "  git add -A && git commit && git push"
if ($To -ne 'client' -or $mod.Side -ne 'client') {
    Say ""
    Say "  Состав серверных модов изменился — перезапустите сервер" Yellow
    Say "  до того, как зайдут игроки." Yellow
}
