<#
    add-mods.ps1 — добавление модов в пак.

    Кладёте jar-ники в mods\, запускаете скрипт. Он опознаёт их через
    CurseForge и Modrinth, превращает в метафайлы, обновляет индекс,
    коммитит и пушит. Опознанные jar удаляются, неопознанные остаются.

    Начиная с этой версии скрипт сам расставляет side (client/server/both).
    Источники, в порядке убывания приоритета:
        1) $SideOverrides — ручные решения ниже, они всегда главнее;
        2) environment из Modrinth API v3 для конкретной версии файла
           (ищется по SHA-1 самого jar, поэтому не зависит от slug);
        3) "environment" из fabric.mod.json внутри jar (моды под Connector);
        4) both — безопасный дефолт.

    Почему не хватало того, что делает сам packwiz: он берёт из Modrinth v2
    поля client_side/server_side и считает мод нужным на стороне, если там
    стоит "required" ИЛИ "optional". У подавляющего большинства проектов
    выставлено optional/optional, поэтому всё и приезжало как both.

    Запуск из корня пака:
        .\add-mods.ps1                       обычный прогон
        .\add-mods.ps1 -Version 1.1.0        заодно поднять версию пака
        .\add-mods.ps1 -NoPush               без git push
        .\add-mods.ps1 -DryRun               ничего не менять, только показать
        .\add-mods.ps1 -Recheck              аудит сторон по всему паку (только отчёт)
        .\add-mods.ps1 -Recheck -Apply       аудит + записать изменения
#>

param(
    [string]$PackDir = $PSScriptRoot,
    [string]$Version,
    [switch]$NoPush,
    [switch]$DryRun,
    [switch]$Recheck,
    [switch]$Apply,
    [switch]$NoAsk
)

$ErrorActionPreference = 'Stop'

# ======================================================================
#  РУЧНЫЕ РЕШЕНИЯ ПО СТОРОНАМ
#  Ключ — имя метафайла без .pw.toml. Побеждает любые данные из API.
#  Сюда вписываем всё, что мы проверили руками и где Modrinth врёт.
# ======================================================================
$SideOverrides = @{
    # --- библиотеки: сторона по самому строгому зависимому моду --------
    'geckolib'                  = 'both'   # от него зависят Alex's Caves, Doggy Talents
    'creativecore'              = 'both'   # dependency-check на сервере
    'lithostitched'             = 'both'   # worldgen-либа, но её требуют both-моды
    'bookshelf'                 = 'both'
    'lodestone'                 = 'both'
    'placebo'                   = 'both'
    'curios'                    = 'both'

    # --- проверено в бою ----------------------------------------------
    'coastal-waves'             = 'both'   # регистрирует канал без .optional()
    'iceberg'                   = 'client' # Modrinth помечен client_and_server — неверно
    'konkrete'                  = 'client'
    'melody'                    = 'client'
    'prism-lib'                 = 'client'
    'ssrd'                      = 'client'

    # --- очевидно клиентские, но в API помечены как both ---------------
    '3dskinlayers'              = 'client'
    'reeses-sodium-options'     = 'client'
    'voxy'                      = 'client'
    'dynamiclights-reforged'    = 'client'
    'shulkerboxtooltip'         = 'client'
    'jade-addons'               = 'client'
    'jade-sable-compat'         = 'client'
    'irisshaders'               = 'client'
    'entity-texture-features-fabric' = 'client'
    'create-better-fps'         = 'client'

    # --- серверные -----------------------------------------------------
    'chunky-pregenerator-forge' = 'server'
    'serene-seasons-gen-fix'    = 'server'
    'skinrestorer'              = 'server'
    'survival-island'           = 'server'

    # чистая генерация мира: структуры и биомы синхронизируются датапаком,
    # статических реестров моды не добавляют — клиенту они не нужны
    'yungs-better-caves'                    = 'server'
    'yungs-better-desert-temples-neoforge'  = 'server'
    'yungs-better-dungeons-neoforge'        = 'server'
    'yungs-better-end-island-neoforge'      = 'server'
    'yungs-better-jungle-temples-neoforge'  = 'server'
    'yungs-better-mineshafts-neoforge'      = 'server'
    'yungs-better-nether-fortresses-neoforge' = 'server'
    'yungs-better-ocean-monuments-neoforge' = 'server'
    'yungs-better-strongholds-neoforge'     = 'server'
    'yungs-better-witch-huts-neoforge'      = 'server'
    'yungs-bridges-neoforge'                = 'server'
    'yungs-extras-neoforge'                 = 'server'
    'yungs-api-neoforge'                    = 'both'   # сама либа нужна обеим
    'more-density-functions'                = 'server'
    'netherportalfix'                       = 'server'
    'better-safe-bed'                       = 'server'
    'rightclickharvest'                     = 'server'
    'ksyxis'                                = 'server'
    'better-than-mending'                   = 'server'

    # --- спорные: API говорит server_only, но мы не проверяли -----------
    # Держим both до теста, чтобы не выбить игроков по несовпадению реестров.
    'create_oxidized'           = 'both'
    'seasonal-lets-do'          = 'both'
}

# environment из Modrinth v3 -> side в packwiz
$EnvClient = @('client_only', 'client_only_server_optional', 'singleplayer_only')
$EnvServer = @('server_only', 'server_only_client_optional', 'dedicated_server_only')
# всё остальное (client_and_server, client_or_server, *_prefers_both, unknown) -> both

# ======================================================================

# Read-Host в PowerShell 5.1 при chcp 65001 возвращает «?» вместо кириллицы,
# пока консоли не задана кодировка явно.
try {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    [Console]::InputEncoding  = New-Object Text.UTF8Encoding $false
} catch { }

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

# Get-Content в PowerShell 5.1 читает файл без BOM в системной ANSI-кодировке.
# UTF-8 при этом превращается в мусор. Читаем и пишем байты сами.
function Read-Utf8($path) {
    [IO.File]::ReadAllText((Resolve-Path $path).Path,
        (New-Object Text.UTF8Encoding $false))
}

function Write-Utf8($path, $text) {
    [IO.File]::WriteAllText((Resolve-Path $path).Path, $text,
        (New-Object Text.UTF8Encoding $false))
}

function Append-Utf8($path, $text) {
    if (-not (Test-Path $path)) { New-Item $path -ItemType File -Force | Out-Null }
    [IO.File]::AppendAllText(
        (Resolve-Path $path).Path, $text, (New-Object Text.UTF8Encoding $false))
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = @{ 'User-Agent' = 'packwiz-helper/2.0 (private modpack)' }

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

# ConvertTo-Json в PS 5.1 схлопывает массив из одного элемента в скаляр,
# а Modrinth ждёт именно массив. Собираем JSON руками — там только хеши
# и id, экранировать нечего.
function To-JsonArray([string[]]$items) {
    '["' + (($items | ForEach-Object { $_ }) -join '","') + '"]'
}

function Env-ToSide($envs) {
    $s = @($envs | Where-Object { $_ } | Sort-Object -Unique)
    if ($s.Count -eq 0) { return $null }
    $onlyClient = $true; $onlyServer = $true
    foreach ($e in $s) {
        if ($EnvClient -notcontains $e) { $onlyClient = $false }
        if ($EnvServer -notcontains $e) { $onlyServer = $false }
    }
    if ($onlyClient) { return 'client' }
    if ($onlyServer) { return 'server' }
    return 'both'
}

# --- Modrinth: environment по хешам файлов ----------------------------
# POST /v3/version_files отдаёт данные конкретной версии, а не проекта,
# поэтому ответ точнее, чем project.environment (там объединение по всем
# версиям и загрузчикам).
function Get-EnvByHash([string[]]$hashes, [string]$algo) {
    $map = @{}
    if ($hashes.Count -eq 0) { return $map }
    try {
        $body = '{"hashes":' + (To-JsonArray $hashes) + ',"algorithm":"' + $algo + '"}'
        $resp = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v3/version_files' `
                    -ContentType 'application/json' -Headers $UA `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body))
        foreach ($pr in $resp.PSObject.Properties) {
            $map[$pr.Name.ToLower()] = $pr.Value
        }
    } catch {
        Say "  Modrinth v3 не ответил ($algo): $($_.Exception.Message)" Yellow
    }
    return $map
}

function Get-EnvByProjectId([string[]]$ids) {
    $map = @{}
    if ($ids.Count -eq 0) { return $map }
    for ($i = 0; $i -lt $ids.Count; $i += 40) {
        $chunk = @($ids[$i..([Math]::Min($i + 39, $ids.Count - 1))])
        try {
            $url = 'https://api.modrinth.com/v3/projects?ids=' +
                   [Uri]::EscapeDataString((To-JsonArray $chunk))
            $resp = Invoke-RestMethod -Headers $UA -Uri $url
            foreach ($p in $resp) { $map[$p.id] = $p.environment }
        } catch {
            Say "  Modrinth v3 projects не ответил: $($_.Exception.Message)" Yellow
        }
        Start-Sleep -Milliseconds 300
    }
    return $map
}

# --- fabric.mod.json внутри jar ---------------------------------------
# Для модов под Sinytra Connector это единственный честный источник:
# "environment": "client" | "server" | "*"
Add-Type -AssemblyName System.IO.Compression.FileSystem -EA SilentlyContinue
function Get-JarSide($jarPath) {
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($jarPath)
        try {
            $e = $zip.Entries | Where-Object { $_.FullName -eq 'fabric.mod.json' } |
                 Select-Object -First 1
            if (-not $e) { return $null }
            $sr = New-Object IO.StreamReader($e.Open(), (New-Object Text.UTF8Encoding $false))
            try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $zip.Dispose() }
    } catch { return $null }

    if ($txt -match '"environment"\s*:\s*"client"') { return 'client' }
    if ($txt -match '"environment"\s*:\s*"server"') { return 'server' }
    return $null
}

# --- запись side в метафайл -------------------------------------------
function Set-MetafileSide($path, $want) {
    $text = Read-Utf8 $path
    if ($text -match '(?m)^side\s*=\s*"(.+?)"') {
        if ($Matches[1] -eq $want) { return $false }
        $new = [regex]::Replace($text, '(?m)^side\s*=\s*".+?"', "side = `"$want`"", 1)
    } elseif ($text -match '(?m)^filename\s*=\s*".+?"') {
        $new = [regex]::Replace($text, '(?m)^(filename\s*=\s*".+?")',
                                "`$1`nside = `"$want`"", 1)
    } else {
        Say "    в $path нет filename — не трогаю" Yellow
        return $false
    }
    Write-Utf8 $path $new
    return $true
}

function Get-MetafileField($text, $field) {
    if ($text -match ('(?m)^' + [regex]::Escape($field) + '\s*=\s*"(.*)"')) { $Matches[1] }
    else { $null }
}

Set-Location $PackDir
if (-not (Test-Path 'pack.toml')) {
    Say "pack.toml не найден. Скрипт должен лежать в корне пака." Red
    exit 1
}

# ======================================================================
#  РЕЖИМ АУДИТА: пересчитать стороны для всего пака
# ======================================================================
if ($Recheck) {
    Head "Аудит сторон по всему паку"

    $files = @(Get-ChildItem 'mods\*.pw.toml' -EA SilentlyContinue)
    Say "  метафайлов: $($files.Count)"

    $meta = @{}
    $byHash = @{ sha1 = @(); sha512 = @(); sha256 = @() }
    $projIds = @()

    foreach ($f in $files) {
        $stem = $f.BaseName -replace '\.pw$', ''
        $t    = Read-Utf8 $f.FullName
        $cur  = Get-MetafileField $t 'side'; if (-not $cur) { $cur = 'both' }
        $algo = Get-MetafileField $t 'hash-format'
        $hash = Get-MetafileField $t 'hash'
        $mid  = if ($t -match '(?ms)\[update\.modrinth\].*?mod-id\s*=\s*"(.*?)"') { $Matches[1] } else { $null }

        $meta[$stem] = [pscustomobject]@{
            Stem = $stem; Path = $f.FullName; Current = $cur
            Algo = $algo; Hash = ($(if ($hash) { $hash.ToLower() } else { $null })); ModId = $mid
        }
        if ($hash -and $byHash.ContainsKey($algo)) { $byHash[$algo] += $hash.ToLower() }
        if ($mid) { $projIds += $mid }
    }

    $envByHash = @{}
    foreach ($algo in @('sha1', 'sha512')) {
        if ($byHash[$algo].Count -gt 0) {
            Say "  запрашиваю Modrinth по $($byHash[$algo].Count) хешам ($algo)" DarkGray
            $r = Get-EnvByHash $byHash[$algo] $algo
            foreach ($k in $r.Keys) { $envByHash[$k] = $r[$k].environment }
        }
    }
    $envByProj = Get-EnvByProjectId @($projIds | Sort-Object -Unique)

    $rows = @()
    foreach ($m in ($meta.Values | Sort-Object Stem)) {
        $src = ''; $want = $null

        if ($SideOverrides.ContainsKey($m.Stem)) {
            $want = $SideOverrides[$m.Stem]; $src = 'ручное'
        }
        if (-not $want -and $m.Hash -and $envByHash.ContainsKey($m.Hash)) {
            $want = Env-ToSide @($envByHash[$m.Hash]); $src = 'modrinth:file'
        }
        if (-not $want -and $m.ModId -and $envByProj.ContainsKey($m.ModId)) {
            $want = Env-ToSide @($envByProj[$m.ModId]); $src = 'modrinth:project'
        }
        if (-not $want) { $want = 'both'; $src = 'дефолт' }

        $rows += [pscustomobject]@{
            Stem = $m.Stem; Path = $m.Path; From = $m.Current; To = $want; Src = $src
        }
    }

    $diff = @($rows | Where-Object { $_.From -ne $_.To })

    Head "Расхождений: $($diff.Count)"
    foreach ($r in ($diff | Sort-Object To, Stem)) {
        $c = switch ($r.To) { 'client' { 'Yellow' } 'server' { 'Magenta' } default { 'Green' } }
        Say ("  {0,-45} {1,-6} -> {2,-6}  [{3}]" -f $r.Stem, $r.From, $r.To, $r.Src) $c
    }

    $unknown = @($rows | Where-Object { $_.Src -eq 'дефолт' })
    if ($unknown.Count -gt 0) {
        Head "Нет данных, оставлено both ($($unknown.Count))"
        Say "  Это моды не с Modrinth (CurseForge, GitHub Releases). Если среди" DarkGray
        Say "  них есть односторонние — впишите их в `$SideOverrides наверху." DarkGray
        $unknown | ForEach-Object { Say "  $($_.Stem)" DarkGray }
    }

    if (-not $Apply) {
        Say ""
        Say "Только отчёт. Чтобы применить: .\add-mods.ps1 -Recheck -Apply" Magenta
        exit 0
    }

    $n = 0
    foreach ($r in $diff) { if (Set-MetafileSide $r.Path $r.To) { $n++ } }
    Say ""
    Say "Изменено метафайлов: $n" Green
    & packwiz refresh
    Say "Теперь проверьте git diff и закоммитьте." Yellow
    exit 0
}

# ======================================================================
#  ОБЫЧНЫЙ РЕЖИМ
# ======================================================================

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
    Say "Для аудита сторон: .\add-mods.ps1 -Recheck" DarkGray
    exit 0
}

# ---------- 0. стороны — ДО того, как jar исчезнут ----------
# CurseForge detect удаляет опознанные jar, поэтому всё, что нужно достать
# из самих файлов (хеш, fabric.mod.json), считаем прямо сейчас.
$sideByJar = @{}
if ($jars.Count -gt 0) {
    Head "Определение стороны ($($jars.Count) файлов)"

    $hashOf = @{}
    foreach ($j in $jars) {
        $hashOf[$j.Name] = (Get-FileHash $j.FullName -Algorithm SHA1).Hash.ToLower()
    }
    $envMap = Get-EnvByHash @($hashOf.Values) 'sha1'

    foreach ($j in $jars) {
        $h    = $hashOf[$j.Name]
        $side = $null; $src = ''

        if ($envMap.ContainsKey($h)) {
            $side = Env-ToSide @($envMap[$h].environment)
            $src  = "modrinth: $(@($envMap[$h].environment) -join ',')"
        }
        if (-not $side) {
            $side = Get-JarSide $j.FullName
            if ($side) { $src = 'fabric.mod.json' }
        }
        if (-not $side) { $side = 'both'; $src = 'нет данных, дефолт' }

        $sideByJar[$j.Name] = $side
        $c = switch ($side) { 'client' { 'Yellow' } 'server' { 'Magenta' } default { 'DarkGray' } }
        Say ("  {0,-55} {1,-6} ({2})" -f $j.Name, $side, $src) $c
    }
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
        $body = '{"hashes":' + (To-JsonArray @($byHash.Keys)) + ',"algorithm":"sha1"}'
        $resp = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' `
                  -ContentType 'application/json' -Headers $UA `
                  -Body ([Text.Encoding]::UTF8.GetBytes($body))
        foreach ($pr in $resp.PSObject.Properties) { $hits[$pr.Name.ToLower()] = $pr.Value }
    } catch {
        Say "  запрос к Modrinth не удался: $($_.Exception.Message)" Yellow
    }

    if ($hits.Count -gt 0) {
        $ids = @($hits.Values | ForEach-Object { $_.project_id } | Sort-Object -Unique)
        $projects = Invoke-RestMethod -Headers $UA `
            -Uri ("https://api.modrinth.com/v2/projects?ids=" +
                  [Uri]::EscapeDataString((To-JsonArray $ids)))
        $slug = @{}
        foreach ($p in $projects) { $slug[$p.id] = $p.slug }

        foreach ($h in $hits.Keys) {
            $v    = $hits[$h]
            $s    = $slug[$v.project_id]
            $jar  = $byHash[$h]
            $ldrs = @($v.loaders) -join ', '
            Say "  $($jar.Name)  ->  $s  [$ldrs]"
            if ($DryRun) { continue }

            # Ставим по version-id, а не по slug. Так в пак попадает ровно тот
            # файл, который лежит в mods, и — главное — packwiz не отсеивает
            # его по загрузчику: installVersionById обходит проверку
            # совместимости. Для Fabric-модов под Sinytra Connector (Axiom,
            # voxy) это единственный способ добавить их в NeoForge-пак.
            $r = Run-Native packwiz modrinth add --version-id $v.id
            $r | ForEach-Object { Say "    $_" DarkGray }

            if ($LASTEXITCODE -ne 0) {
                Say "    по version-id не вышло, пробую по названию" Yellow
                $r = Run-Native packwiz modrinth add $s
                $r | ForEach-Object { Say "    $_" DarkGray }
            }

            if ($LASTEXITCODE -eq 0) {
                Remove-Item $jar.FullName -Force
                if ($ldrs -and $ldrs -notmatch 'neoforge|forge') {
                    Say "    ВНИМАНИЕ: мод собран под $ldrs — нужен Sinytra Connector" Yellow
                }
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
    Say "  Если мод есть на Modrinth, но packwiz его не берёт — скорее" DarkGray
    Say "  всего не совпал загрузчик. Добавьте по идентификатору версии," DarkGray
    Say "  он обходит проверку совместимости:" DarkGray
    Say "    packwiz modrinth add --version-id <id>" DarkGray
    Say "  Идентификатор виден в адресе страницы версии на Modrinth." DarkGray
    Say "" DarkGray
    Say "  Если мода нет ни на Modrinth, ни на CurseForge — залейте jar" DarkGray
    Say "  в GitHub Releases и добавьте по прямой ссылке:" DarkGray
    Say "    packwiz url add <имя> <прямая-ссылка-на-jar>" DarkGray
}

# ---------- 4. что появилось ----------
$after = @(Get-Metafiles)
$new   = @($after | Where-Object { $before -notcontains $_ })

if ($new.Count -gt 0) {
    Head "Добавлено модов: $($new.Count)"
    $new | Sort-Object | ForEach-Object { Say "  $_" Green }
}

# ---------- 4.5. проставляем side новым модам ----------
# Метафайл ищем по полю filename: имя метафайла — это slug площадки, а он
# у CurseForge и Modrinth бывает разный (и вообще может совпасть с чужим
# проектом, как «bookshelf» или «lodestone»). Имя jar однозначно.
$needReview = @()
if ($new.Count -gt 0 -and -not $DryRun) {
    Head "Расстановка side"

    foreach ($id in $new) {
        $path = "mods\$id.pw.toml"
        if (-not (Test-Path $path)) { continue }
        $t   = Read-Utf8 $path
        $jar = Get-MetafileField $t 'filename'

        $want = $null; $src = ''
        if ($SideOverrides.ContainsKey($id)) {
            $want = $SideOverrides[$id]; $src = 'ручное правило'
        } elseif ($jar -and $sideByJar.ContainsKey($jar)) {
            $want = $sideByJar[$jar]; $src = 'по jar'
        } else {
            # jar уже удалён CurseForge detect и в карте его нет — берём
            # то, что packwiz успел записать сам
            $want = Get-MetafileField $t 'side'
            if (-not $want) { $want = 'both' }
            $src = 'packwiz'
            $needReview += $id
        }

        $changed = Set-MetafileSide $path $want
        $mark = if ($changed) { '*' } else { ' ' }
        $c = switch ($want) { 'client' { 'Yellow' } 'server' { 'Magenta' } default { 'DarkGray' } }
        Say ("  {0} {1,-45} {2,-6} ({3})" -f $mark, $id, $want, $src) $c
    }

    # интерактивная правка — API часто врёт, дешевле переспросить сразу
    if (-not $NoAsk) {
        Say ""
        $ans = Read-Host "  Поправить какие-то стороны вручную? (имя мода / Enter — нет)"
        while ($ans) {
            $p = "mods\$ans.pw.toml"
            if (-not (Test-Path $p)) {
                Say "    нет такого метафайла" Red
            } else {
                $s = Read-Host "    side для $ans (client/server/both)"
                if ($s -in @('client', 'server', 'both')) {
                    [void](Set-MetafileSide $p $s)
                    Say "    -> $s (не забудьте добавить в `$SideOverrides)" Green
                } else { Say "    непонятное значение" Red }
            }
            $ans = Read-Host "  Ещё? (имя мода / Enter — нет)"
        }
    }

    if ($needReview.Count -gt 0) {
        Say ""
        Say "  Стороны не проверены по jar (мод пришёл с CurseForge):" Yellow
        $needReview | ForEach-Object { Say "    $_" Yellow }
    }
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
        $side = Get-MetafileField $t 'side'; if (-not $side) { $side = 'both' }
        if ($side -ne 'client') { continue }
        if ($toml -match [regex]::Escape("[metafile.`"$id`"]")) { continue }
        if ($toml -match [regex]::Escape("[metafile.$id]"))     { continue }
        $name = Get-MetafileField $t 'name'; if (-not $name) { $name = $id }
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

if ($new.Count -gt 0 -and -not $DryRun -and -not $NoAsk) { Update-Flavors $new }

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
        if (-not $DryRun) { Write-Utf8 $f $t }
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
