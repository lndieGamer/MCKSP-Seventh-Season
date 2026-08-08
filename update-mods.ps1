<#
    update-mods.ps1 — проверка и установка обновлений модов в паке.

    Работает через packwiz update. Порядок такой: снимок метафайлов до,
    обновление, снимок после, разбор что именно поменялось. Откат при
    проверке делается через git, поэтому дерево должно быть чистым.

    Запуск из корня пака:
        .\update-mods.ps1                 обновить всё, закоммитить и запушить
        .\update-mods.ps1 -CheckOnly      только показать, что доступно
        .\update-mods.ps1 -Mod create     обновить один мод
        .\update-mods.ps1 -NoPush         коммит без отправки
        .\update-mods.ps1 -Force          не требовать чистого дерева
#>

param(
    [string]$PackDir,
    [string]$Mod,
    [switch]$CheckOnly,
    [switch]$NoPush,
    [switch]$Force
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

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Head($t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }

# У части модов в name есть эмодзи (например "Jade 🔍"). Это суррогатная
# пара: консоль её не рисует, а Length считает за два символа и ломает
# выравнивание колонок. Для вывода чистим, в коммит идёт исходное имя.
function Plain($t) {
    ($t -replace '[\uD800-\uDFFF]', '').Trim()
}

# ---------- где лежит пак ----------
# Скрипт может лежать где угодно: ищем pack.toml рядом с ним, затем вверх
# по родительским папкам, затем от текущего каталога.
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
        Say "В указанной папке нет pack.toml: $PackDir" Red
        exit 1
    }
    $root = (Resolve-Path $PackDir).Path
} else {
    $looked = @($PSScriptRoot, (Get-Location).Path)
    $root = Find-PackRoot $looked
    if (-not $root) {
        Say "pack.toml не найден." Red
        Say "  Искал рядом со скриптом и выше по дереву от:" DarkGray
        $looked | Where-Object { $_ } | ForEach-Object { Say "    $_" DarkGray }
        Say "  Укажите папку явно: -PackDir C:\путь\к\паку" Yellow
        exit 1
    }
}

Set-Location $root
Say "Пак: $root" DarkGray
foreach ($exe in @('packwiz', 'git')) {
    if (-not (Get-Command $exe -EA SilentlyContinue)) {
        Say "$exe не найден в PATH." Red
        exit 1
    }
}

# ---------- снимок метафайлов ----------
function Get-Snapshot {
    $r = @{}
    foreach ($f in Get-ChildItem -Recurse -Filter '*.pw.toml' -EA SilentlyContinue) {
        $t = Read-Utf8 $f.FullName
        $id = $f.BaseName -replace '\.pw$', ''
        $r[$id] = [pscustomobject]@{
            Id       = $id
            Name     = if ($t -match '(?m)^name\s*=\s*"(.*)"')     { $Matches[1] } else { $id }
            FileName = if ($t -match '(?m)^filename\s*=\s*"(.*)"') { $Matches[1] } else { '' }
            Side     = if ($t -match '(?m)^side\s*=\s*"(.*)"')     { $Matches[1] } else { 'both' }
            Hash     = if ($t -match '(?m)^hash\s*=\s*"(.*)"')        { $Matches[1].ToLower() } else { '' }
            HashFmt  = if ($t -match '(?m)^hash-format\s*=\s*"(.*)"') { $Matches[1] } else { '' }
            Pinned   = $t -match '(?m)^pin\s*=\s*true'
        }
    }
    $r
}

# из имени файла вытаскиваем что-то похожее на версию
function Get-Ver($fileName) {
    if ($fileName -match '(\d+[\d.]*[\w.+-]*)\.jar$') { $Matches[1] } else { $fileName }
}

# ---------- проверка отставших зависимостей ----------
# Опознаём моды на Modrinth по хешу jar (так же, как это делает add-mods).
# Modrinth отдаёт для версии список зависимостей и дату публикации — этого
# хватает, чтобы поймать случай, ради которого всё затевалось: аддон собран
# под старую версию своей зависимости, а зависимость уехала вперёд.
# Именно так сломался CarryOnAeroCompat, уронив сервер при клике по блоку.
function Get-ModrinthVersions($snapshot) {
    $UA   = @{ 'User-Agent' = 'mckspack-helper/1.0 (private modpack)' }
    $res  = @{}
    foreach ($algo in @('sha1', 'sha512')) {
        $hashes = @($snapshot.Values |
            Where-Object { $_.HashFmt -eq $algo -and $_.Hash } |
            ForEach-Object { $_.Hash })
        if ($hashes.Count -eq 0) { continue }
        try {
            $body = @{ hashes = $hashes; algorithm = $algo } | ConvertTo-Json -Compress
            $r = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' `
                    -ContentType 'application/json' -Headers $UA `
                    -Body ([Text.Encoding]::UTF8.GetBytes($body))
            foreach ($pr in $r.PSObject.Properties) { $res[$pr.Name.ToLower()] = $pr.Value }
        } catch {
            Say "  запрос к Modrinth ($algo) не удался: $($_.Exception.Message)" Yellow
        }
    }
    $res
}

function Warn-StaleDeps($snapshot, $changedIds) {
    Head "Проверка зависимостей"

    $vers = Get-ModrinthVersions $snapshot
    if ($vers.Count -eq 0) {
        Say "  не удалось опознать ни одного мода — проверка пропущена" Yellow
        return
    }

    # project_id -> сведения о нашей версии мода
    $byProject = @{}
    $byId      = @{}
    foreach ($m in $snapshot.Values) {
        if (-not $m.Hash) { continue }
        $v = $vers[$m.Hash]
        if (-not $v) { continue }
        $rec = [pscustomobject]@{
            Id   = $m.Id
            Name = $m.Name
            Date = $v.date_published
            Deps = $v.dependencies
        }
        $byProject[$v.project_id] = $rec
        $byId[$m.Id] = $rec
    }
    Say "  опознано на Modrinth: $($byProject.Count) из $($snapshot.Count)" DarkGray

    $risky = @()
    $lag   = 0
    foreach ($m in $byProject.Values) {
        foreach ($d in $m.Deps) {
            if ($d.dependency_type -ne 'required') { continue }
            $dep = $byProject[$d.project_id]
            if (-not $dep) { continue }
            if ($dep.Date -le $m.Date) { continue }
            $lag++
            # опасно именно сейчас: зависимость обновилась в этом прогоне,
            # а сам аддон остался прежним
            if (($changedIds -contains $dep.Id) -and -not ($changedIds -contains $m.Id)) {
                $risky += [pscustomobject]@{ Mod = $m.Name; Dep = $dep.Name }
            }
        }
    }

    if ($risky.Count -gt 0) {
        Say ""
        Say "  ВНИМАНИЕ: $($risky.Count) модов могли отстать от своих зависимостей" Red
        foreach ($r in ($risky | Sort-Object Mod)) {
            Say ("    {0}  ->  зависит от {1}, которая только что обновилась" -f (Plain $r.Mod), (Plain $r.Dep)) Yellow
        }
        Say ""
        Say "  Это не гарантия поломки, но именно так ломаются миксины:" DarkGray
        Say "  аддон ищет метод, которого в новой версии зависимости уже нет." DarkGray
        Say "  Проверьте эти моды в игре перед тем, как пускать игроков." DarkGray
    } else {
        Say "  зависимостей, обновившихся впереди своих аддонов, нет" Green
    }

    if ($lag -gt $risky.Count) {
        Say ""
        Say "  Ещё $($lag - $risky.Count) модов старше своих зависимостей по дате," DarkGray
        Say "  но обновились они не сейчас — обычно это безобидно (стабильные API)." DarkGray
    }
}

# ---------- состояние git ----------
if ((& git rev-parse --is-inside-work-tree 2>$null) -ne 'true') {
    Say "Это не git-репозиторий: $root" Red
    Say "  Скрипту нужен git — и для отката при -CheckOnly, и для коммита." Yellow
    exit 1
}

# Откат делается через git checkout, а он трогает только отслеживаемые
# файлы. Неотслеживаемые (сами скрипты, мусор) откату не мешают, поэтому
# на них не ругаемся.
$status    = @(& git status --porcelain)
# Не -like '??*': в PowerShell ? — это подстановочный знак «любой символ»,
# и такой шаблон совпал бы с любой строкой. Сравниваем начало явно.
$untracked = @($status | Where-Object { $_.StartsWith('??') })
$dirty     = @($status | Where-Object { -not $_.StartsWith('??') })

if ($dirty.Count -gt 0 -and -not $Force) {
    Head "В паке есть незакоммиченные правки"
    $dirty | ForEach-Object { Say "  $_" Yellow }
    Say ""
    Say "  Закоммитьте или отложите их — иначе непонятно, что из правок" Yellow
    Say "  сделал packwiz, а откат при -CheckOnly затрёт ваше." Yellow
    Say "  Обойти проверку: -Force" DarkGray
    exit 1
}
if ($untracked.Count -gt 0) {
    Say "  неотслеживаемых файлов: $($untracked.Count) (откату не мешают)" DarkGray
}

# ---------- подтягиваем чужие правки ----------
# Пак редактируют несколько человек. Обновляться на устаревшей копии нельзя:
# конфликт вылезет в index.toml, где сотни записей.
Head "Синхронизация с GitHub"
# ветка без upstream — тянуть неоткуда, но и конфликтовать не с чем
$null = & git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
$hasUpstream = ($LASTEXITCODE -eq 0)

if (-not $hasUpstream) {
    Say "  у ветки нет upstream — тянуть неоткуда, пропускаю" Yellow
} else {
$pull = & git pull --ff-only 2>&1
$pull | ForEach-Object { Say "  $_" DarkGray }
if ($LASTEXITCODE -ne 0) {
    Say ""
    Say "  git pull не прошёл. Возможные причины:" Red
    Say "    - ваши коммиты разошлись с удалёнными (нужен rebase или merge)" Yellow
    Say "    - нет доступа к сети или к репозиторию" Yellow
    Say "  Разберитесь с этим и запустите скрипт заново." Yellow
    exit 1
}
}

$before = Get-Snapshot
Head "Начальное состояние"
Say "  метафайлов: $($before.Count)"
$pinned = @($before.Values | Where-Object { $_.Pinned })
if ($pinned.Count -gt 0) {
    Say "  закреплено (обновляться не будут): $($pinned.Count)" DarkGray
    $pinned | Sort-Object Name | ForEach-Object { Say "    $($_.Name)" DarkGray }
}

# ---------- обновление ----------
Head $(if ($Mod) { "packwiz update $Mod" } else { "packwiz update --all" })

$out = if ($Mod) {
    & packwiz update $Mod -y 2>&1 | Tee-Object -Variable captured
} else {
    & packwiz update --all -y 2>&1 | Tee-Object -Variable captured
}
$out | ForEach-Object { Say "  $_" DarkGray }

if ($LASTEXITCODE -ne 0) {
    Say "`npackwiz завершился с ошибкой." Red
    exit 1
}

# моды без механизма обновления — их packwiz не проверяет вообще
$noUpdater = @($captured |
    Where-Object { $_ -match 'update system for "(.*)" cannot be found' } |
    ForEach-Object { [regex]::Match($_, 'update system for "(.*)" cannot be found').Groups[1].Value } |
    Sort-Object -Unique)

# ---------- что поменялось ----------
$after   = Get-Snapshot
$changed = @()
foreach ($id in $after.Keys) {
    if (-not $before.ContainsKey($id)) { continue }
    if ($before[$id].FileName -ne $after[$id].FileName) {
        $changed += [pscustomobject]@{
            Id   = $id
            Name = $after[$id].Name
            Side = $after[$id].Side
            From = Get-Ver $before[$id].FileName
            To   = Get-Ver $after[$id].FileName
        }
    }
}

if ($noUpdater.Count -gt 0) {
    Head "Без автообновления ($($noUpdater.Count))"
    Say "  Эти моды packwiz не проверяет — добавлены по прямой ссылке." DarkGray
    $noUpdater | ForEach-Object { Say "  $_" DarkGray }
}

if ($changed.Count -eq 0) {
    Head "Обновлений нет"
    Say "  Все моды на актуальных версиях." Green
    if ($dirty.Count -gt 0) { Say "`n  Незакоммиченные правки остались как были." Yellow }
    exit 0
}

$srv = @($changed | Where-Object { $_.Side -ne 'client' })
$cli = @($changed | Where-Object { $_.Side -eq 'client' })

Head "Обновлено модов: $($changed.Count)"
$w = ($changed | ForEach-Object { (Plain $_.Name).Length } | Measure-Object -Maximum).Maximum
foreach ($c in ($changed | Sort-Object Name)) {
    $pad  = (Plain $c.Name).PadRight($w)
    $mark = if ($c.Side -eq 'client') { '  ' } else { '!!' }
    $col  = if ($c.Side -eq 'client') { 'Gray' } else { 'Yellow' }
    Say ("  {0} {1}  {2} -> {3}" -f $mark, $pad, $c.From, $c.To) $col
}
Say ""
Say "  !! — мод есть и на сервере ($($srv.Count) шт.), только клиент: $($cli.Count)" DarkGray

Warn-StaleDeps $after @($changed | ForEach-Object { $_.Id })

# ---------- режим проверки ----------
if ($CheckOnly) {
    Head "Откат"
    & git checkout -- .
    if ($LASTEXITCODE -eq 0) {
        Say "  Метафайлы возвращены в исходное состояние." Green
        Say "  Запустите без -CheckOnly, чтобы применить." DarkGray
    } else {
        Say "  Откат не прошёл — проверьте git status вручную." Red
        exit 1
    }
    exit 0
}

# ---------- список для сервера ----------
# Кладём рядом с паком, но прячем от packwiz: иначе файл уедет игрокам.
$ignore = '.packwizignore'
$listName = 'server-mods-expected.txt'
$ign = if (Test-Path $ignore) { (Read-Utf8 $ignore) -split "`r?`n" } else { @() }
if ($ign -notcontains $listName) {
    # имя файла тут чисто ASCII, но пусть везде будет один способ записи
    Append-Utf8 $ignore "$listName`n"
    Say "`n  $listName добавлен в $ignore" DarkGray
}

$srvFiles = @($after.Values | Where-Object { $_.Side -ne 'client' } | ForEach-Object { $_.FileName })
$lines = @(
    "# Моды, которые пак ожидает на сервере (side = both/server)",
    "# Сгенерировано update-mods.ps1, всего: $($srvFiles.Count)",
    ""
) + ($srvFiles | Sort-Object)
[IO.File]::WriteAllLines((Join-Path $root $listName), $lines, (New-Object Text.UTF8Encoding $false))

# ---------- индекс ----------
Head "Обновление индекса"
& packwiz refresh
if ($LASTEXITCODE -ne 0) { Say "  packwiz refresh не прошёл" Red; exit 1 }

# ---------- git ----------
Head "Git"
if (-not (& git status --porcelain)) {
    Say "  изменений нет, коммит не нужен" DarkGray
    exit 0
}

$names = ($changed | Sort-Object Name | ForEach-Object { $_.Name }) -join ', '
$msg   = "update: $names"
if ($msg.Length -gt 200) {
    $msg = "update: обновлено модов — $($changed.Count) (" +
           (($changed | Sort-Object Name | Select-Object -First 3 |
             ForEach-Object { $_.Name }) -join ', ') + " и другие)"
}

& git add -A
& git commit -m $msg
if ($LASTEXITCODE -ne 0) { Say "  коммит не прошёл" Red; exit 1 }

$pushed = $false
if ($NoPush) {
    Say "`n  -NoPush: коммит сделан, отправка пропущена." Yellow
} else {
    & git push
    if ($LASTEXITCODE -eq 0) {
        $pushed = $true
    } else {
        Say "  push не прошёл — отправьте вручную" Red
    }
}

# Предупреждение про сервер показываем всегда: оно про то, что уже
# закоммичено, а не про то, доехало ли до Pages.
Head $(if ($pushed) { "Готово" } else { "Итог" })
if ($srv.Count -gt 0) {
    Say "  ПЕРЕЗАПУСТИТЕ СЕРВЕР ДО ТОГО, КАК ЗАЙДУТ ИГРОКИ." Red
    Say "  Обновилось $($srv.Count) модов, которые есть и на сервере." Yellow
    Say "  Клиенты подтянут новые версии при первом же запуске, и если" Yellow
    Say "  сервер останется на старых — подключение отвалится с ошибкой" Yellow
    Say "  про недостающий сетевой канал." Yellow
    Say ""
    Say "  Сверить сервер: $listName в корне пака." DarkGray
} else {
    Say "  Обновились только клиентские моды, сервер трогать не нужно." Green
}

if (-not $pushed) {
    Say ""
    Say "  Изменения ещё не отправлены — до игроков они не доедут," DarkGray
    Say "  пока не пройдёт git push." DarkGray
}
