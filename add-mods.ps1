<#
    add-mods.ps1 — добавление модов в пак.

    Кладёте jar-ники в mods\, запускаете скрипт. Он опознаёт их через
    CurseForge и Modrinth, превращает в метафайлы, обновляет индекс,
    коммитит и пушит. Опознанные jar удаляются, неопознанные остаются.

    Запуск из корня пака:
        .\add-mods.ps1                      обычный прогон
        .\add-mods.ps1 -Version 1.1.0       заодно поднять версию пака
        .\add-mods.ps1 -NoPush              без git push
        .\add-mods.ps1 -DryRun              ничего не менять, только показать
#>

param(
    [string]$PackDir = $PSScriptRoot,
    [string]$Version,
    [switch]$NoPush,
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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = @{ 'User-Agent' = 'packwiz-helper/1.0 (private modpack)' }

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

Set-Location $PackDir
if (-not (Test-Path 'pack.toml')) {
    Say "pack.toml не найден. Скрипт должен лежать в корне пака." Red
    exit 1
}

# ---------- подтягиваем чужие правки ----------
# Пак редактируют несколько человек. Если начать работу на устаревшей
# копии, конфликт вылезет в index.toml — а там сотни записей, и разбирать
# его руками очень неприятно. Поэтому синхронизируемся до всего остального.
function Sync-Repo {
    if (-not (Get-Command git -EA SilentlyContinue)) {
        Say "git не найден в PATH — пропускаю синхронизацию." Yellow
        return $true
    }
    if ((& git rev-parse --is-inside-work-tree 2>$null) -ne 'true') {
        Say "Это не git-репозиторий — пропускаю синхронизацию." Yellow
        return $true
    }

    Head "Синхронизация с GitHub"

    $null = & git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Say "  у ветки нет upstream — тянуть неоткуда, пропускаю" Yellow
        return $true
    }

    # --ff-only: если ветки разошлись, лучше честно упасть, чем создать
    # merge-коммит поверх чужой работы
    $out = Run-Native git pull --ff-only
    $out | ForEach-Object { Say "  $_" DarkGray }

    if ($LASTEXITCODE -ne 0) {
        Say ""
        Say "  git pull не прошёл. Возможные причины:" Red
        Say "    - ваши коммиты разошлись с удалёнными (нужен rebase или merge)" Yellow
        Say "    - есть незакоммиченные правки, мешающие обновлению" Yellow
        Say "    - нет доступа к сети или к репозиторию" Yellow
        Say "  Разберитесь с этим и запустите скрипт заново." Yellow
        return $false
    }
    return $true
}

if (-not (Sync-Repo)) { exit 1 }

function Get-Metafiles {
    Get-ChildItem 'mods\*.pw.toml' -EA SilentlyContinue |
        ForEach-Object { $_.BaseName -replace '\.pw$', '' }
}

$before = @(Get-Metafiles)
$jars   = @(Get-ChildItem 'mods\*.jar' -EA SilentlyContinue)

Head "Начальное состояние"
Say "  метафайлов: $($before.Count)"
Say "  новых jar:  $($jars.Count)"

if ($jars.Count -eq 0 -and -not $Version) {
    Say "`nНечего добавлять. Положите jar-ники в mods\ и запустите снова." Yellow
    exit 0
}

# ---------- 1. CurseForge ----------
if ($jars.Count -gt 0 -and -not $DryRun) {
    Head "Опознание через CurseForge"
    & packwiz curseforge detect
}

# ---------- 2. Modrinth по хешу ----------
$left = @(Get-ChildItem 'mods\*.jar' -EA SilentlyContinue)
if ($left.Count -gt 0) {
    Head "Опознание через Modrinth ($($left.Count) файлов)"

    $byHash = @{}
    foreach ($j in $left) {
        $byHash[(Get-FileHash $j.FullName -Algorithm SHA1).Hash.ToLower()] = $j
    }

    $hits = @{}
    try {
        $body = @{ hashes = @($byHash.Keys); algorithm = 'sha1' } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' `
                  -ContentType 'application/json' -Headers $UA `
                  -Body ([Text.Encoding]::UTF8.GetBytes($body))
        foreach ($pr in $resp.PSObject.Properties) { $hits[$pr.Name.ToLower()] = $pr.Value }
    } catch {
        Say "  запрос к Modrinth не удался: $($_.Exception.Message)" Yellow
    }

    if ($hits.Count -gt 0) {
        $ids = @($hits.Values | ForEach-Object { $_.project_id } | Sort-Object -Unique)
        $json = $ids | ConvertTo-Json -Compress
        if ($ids.Count -eq 1) { $json = "[$json]" }
        $projects = Invoke-RestMethod -Headers $UA `
            -Uri ("https://api.modrinth.com/v2/projects?ids=" + [Uri]::EscapeDataString($json))
        $slug = @{}
        foreach ($p in $projects) { $slug[$p.id] = $p.slug }

        foreach ($h in $hits.Keys) {
            $s   = $slug[$hits[$h].project_id]
            $jar = $byHash[$h]
            Say "  $($jar.Name)  ->  $s"
            if (-not $DryRun) {
                & packwiz modrinth add $s
                if ($LASTEXITCODE -eq 0) { Remove-Item $jar.FullName -Force }
            }
        }
    }
}

# ---------- 3. что не опозналось ----------
$stuck = @(Get-ChildItem 'mods\*.jar' -EA SilentlyContinue)
if ($stuck.Count -gt 0) {
    Head "Не опознано ($($stuck.Count)) — нужен метафайл вручную"
    $stuck | ForEach-Object { Say "  $($_.Name)" Yellow }
    Say ""
    Say "  Залейте их в GitHub Releases и добавьте так:" DarkGray
    Say "    packwiz url add <имя> <прямая-ссылка-на-jar>" DarkGray
}

# ---------- 4. что появилось ----------
$after = @(Get-Metafiles)
$new   = @($after | Where-Object { $before -notcontains $_ })

if ($new.Count -gt 0) {
    Head "Добавлено модов: $($new.Count)"
    $new | Sort-Object | ForEach-Object { Say "  $_" Green }
    Say ""
    Say "  ВНИМАНИЕ: всем новым модам проставлено side = both." Yellow
    Say "  Если среди них есть чисто клиентские — впишите их в set-sides.ps1" Yellow
    Say "  и в unsup.toml, иначе они уедут на сервер и в облегчённую сборку." Yellow
}

# ---------- 5. галочки в unsup ----------
# Каждый клиентский мод — отдельная галочка в меню выбора. Новый мод без
# привязки в unsup.toml ставится всем и всегда, поэтому спрашиваем про него
# сразу, пока помним, зачем добавляли.
function Update-Flavors($newIds) {
    if (-not (Test-Path 'unsup.toml')) {
        Say "  unsup.toml не найден рядом с pack.toml — пропускаю" Yellow
        return
    }

    $toml = Read-Utf8 'unsup.toml'

    # какие из новых модов клиентские и ещё не привязаны
    $cand = @()
    foreach ($id in $newIds) {
        $f = "mods\$id.pw.toml"
        if (-not (Test-Path $f)) { continue }
        $t = Read-Utf8 $f
        $side = if ($t -match '(?m)^side\s*=\s*"(.*)"') { $Matches[1] } else { 'both' }
        if ($side -ne 'client') { continue }
        if ($toml -match [regex]::Escape("[metafile.`"$id`"]")) { continue }
        if ($toml -match [regex]::Escape("[metafile.$id]"))     { continue }
        $name = if ($t -match '(?m)^name\s*=\s*"(.*)"') { $Matches[1] } else { $id }
        $cand += [pscustomobject]@{ Id = $id; Name = $name }
    }

    if ($cand.Count -eq 0) { return }

    Head "Новые клиентские моды: $($cand.Count)"
    Say "  Для каждого можно завести галочку в меню выбора сборки." DarkGray
    Say "  Пустое название — мод будет ставиться всем и всегда." DarkGray

    $add = ''
    foreach ($c in $cand) {
        Say ""
        Say "  $($c.Name)  [$($c.Id)]" Cyan
        $label = Read-Host "    Название галочки (Enter — без галочки)"
        if (-not $label) { Say "    ставится всегда" DarkGray; continue }
        $desc = Read-Host "    Короткое описание"

        $label = $label -replace '"', "'"
        $desc  = $desc  -replace '"', "'"

        $add += @"

[flavor_groups."$($c.Id)"]
name = "$label"
description = "$desc"
side = "client"

[[flavor_groups."$($c.Id)".choices]]
id = "$($c.Id)_on"
name = "Включить"

[[flavor_groups."$($c.Id)".choices]]
id = "$($c.Id)_off"
name = "Отключить"

[metafile."$($c.Id)"]
flavors = ["$($c.Id)_on"]
"@
        Say "    галочка добавлена" Green
    }

    if (-not $add) { return }
    if ($DryRun) { Say "`n  Сухой прогон — unsup.toml не тронут." Magenta; return }

    Append-Utf8 'unsup.toml' $add
    Say ""
    Say "  unsup.toml дополнен." Green
    Say "  Не забудьте добавить новые группы в setup-mckspack.iss," Yellow
    Say "  иначе установщик про них не спросит и unsup переспросит сам" Yellow
    Say "  при первом запуске игры." Yellow
}

if ($new.Count -gt 0) { Update-Flavors $new }

# ---------- 6. версия пака ----------
if ($Version) {
    Head "Версия пака -> $Version"
    foreach ($f in @('pack.toml', 'config\bcc-common.toml')) {
        if (-not (Test-Path $f)) { Say "  $f не найден, пропускаю" Yellow; continue }
        $t = Read-Utf8 $f
        if ($f -like '*pack.toml') {
            $t = $t -replace '(?m)^version\s*=\s*".*"', "version = `"$Version`""
        } else {
            $t = $t -replace 'modpackVersion\s*=\s*".*"', "modpackVersion = `"$Version`""
        }
        if (-not $DryRun) {
            [IO.File]::WriteAllText((Resolve-Path $f), $t, (New-Object Text.UTF8Encoding $false))
        }
        Say "  $f обновлён"
    }
}

# ---------- 7. индекс ----------
if (-not $DryRun) {
    Head "Обновление индекса"
    & packwiz refresh
}

# ---------- 8. git ----------
Head "Git"
if ($DryRun) {
    & git status --short
    Say "`nСухой прогон — ничего не записано и не отправлено." Magenta
    exit 0
}

$changed = & git status --porcelain
if (-not $changed) {
    Say "  изменений нет, коммит не нужен" DarkGray
    exit 0
}

$msg = if ($new.Count -gt 0) {
    "add: " + (($new | Sort-Object) -join ', ')
} else {
    "chore: обновление пака"
}
if ($Version) { $msg = "$msg (v$Version)" }
if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 197) + '...' }

& git add -A
& git commit -m $msg
if ($LASTEXITCODE -ne 0) { Say "  коммит не прошёл" Red; exit 1 }

if ($NoPush) {
    Say "`n  -NoPush: коммит сделан, отправка пропущена." Yellow
} else {
    & git push
    if ($LASTEXITCODE -eq 0) {
        Say "`nГотово. Через минуту-две изменения доедут до игроков." Green
    } else {
        Say "  push не прошёл — отправьте вручную" Red
    }
}
