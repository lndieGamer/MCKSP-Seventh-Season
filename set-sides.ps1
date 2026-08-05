<#
    set-sides.ps1 (v2) -- assigns the "side" field in packwiz metafiles.

    Matches on the METAFILE NAME, not the jar filename, so mod updates do
    not break the mapping. Anything not listed below defaults to "both".

    Expected result for this pack: 32 client, 4 server, rest both.

    Run from the pack root (next to pack.toml):
        powershell -ExecutionPolicy Bypass -File .\set-sides.ps1 -DryRun
        powershell -ExecutionPolicy Bypass -File .\set-sides.ps1
#>

param(
    [string]$ModsDir = "mods",
    [switch]$DryRun
)

# --- client-only: must NEVER reach the dedicated server -----------------
$clientOnly = @(
    "advancement-plaques"
    "ambientsounds"
    "better-advancements"
    "better-ping-display"
    "coastal-waves"
    "create-better-fps"
    "cubes-without-borders"
    "distant-horizons"
    "enchantment-descriptions"
    "entity-model-features"
    "entity-texture-features-fabric"
    "entityculling"
    "fancymenu"
    "fusion-connected-textures"
    "iceberg"
    "irisshaders"
    "jade-addons"
    "jade-sable-compat"
    "just-zoom"
    "konkrete"
    "legendary-tooltips"
    "melody"
    "more-overlays-updated"
    "mouse-tweaks"
    "particle-rain"
    "prism-lib"
    "skin-layers-3d"
    "sodium"
    "sodium-extra"
    "ssrd"
    "xaeros-minimap"
    "xaeros-world-map"
)

# --- server-only: pointless on the client ------------------------------
$serverOnly = @(
    "chunky-pregenerator-forge"
    "serene-seasons-gen-fix"
    "skinrestorer"
    "survival-island"
)

# Everything else is assumed to be "both".
$default = "both"

if (-not (Test-Path $ModsDir)) {
    Write-Host "Directory '$ModsDir' not found. Run this from the pack root." -ForegroundColor Red
    exit 1
}

$counts  = @{ client = 0; server = 0; both = 0 }
$changed = 0
$jarSeen = @{}
$defaulted = @()

Get-ChildItem -Path $ModsDir -Filter *.pw.toml | ForEach-Object {
    $path = $_.FullName
    $stem = $_.BaseName -replace '\.pw$', ''
    $text = Get-Content -Path $path -Raw -Encoding UTF8

    if     ($clientOnly -contains $stem) { $want = "client" }
    elseif ($serverOnly -contains $stem) { $want = "server" }
    else   { $want = $default; $defaulted += $stem }

    $counts[$want]++

    # collect jar names to spot duplicates
    if ($text -match '(?m)^filename\s*=\s*"(.+?)"') {
        $jar = $Matches[1]
        if (-not $jarSeen.ContainsKey($jar)) { $jarSeen[$jar] = @() }
        $jarSeen[$jar] += $stem
        if ($jar -notmatch '\.jar$') {
            Write-Host "  BROKEN filename in $stem : '$jar' (not a .jar)" -ForegroundColor Red
        }
    } else {
        Write-Host "  no filename field: $stem" -ForegroundColor DarkYellow
    }

    if ($text -match '(?m)^side\s*=\s*"(.+?)"') {
        if ($Matches[1] -eq $want) { return }
        $new = [regex]::Replace($text, '(?m)^side\s*=\s*".+?"', "side = `"$want`"", 1)
    } else {
        $new = [regex]::Replace($text, '(?m)^(filename\s*=\s*".+?")', "`$1`nside = `"$want`"", 1)
    }

    if (-not $DryRun) {
        [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host "  $stem -> $want"
    $changed++
}

Write-Host ""
Write-Host ("totals: client={0}  server={1}  both={2}  (changed this run: {3})" -f `
    $counts.client, $counts.server, $counts.both, $changed) -ForegroundColor Cyan

# --- sanity checks -----------------------------------------------------
if ($counts.client -ne 32 -or $counts.server -ne 4) {
    Write-Host ""
    Write-Host "Expected 32 client / 4 server. Some listed metafiles are missing," -ForegroundColor Yellow
    Write-Host "or were renamed by packwiz. Check the names below." -ForegroundColor Yellow
    $present = (Get-ChildItem -Path $ModsDir -Filter *.pw.toml).BaseName -replace '\.pw$', ''
    foreach ($n in ($clientOnly + $serverOnly)) {
        if ($present -notcontains $n) { Write-Host "  missing metafile: $n" -ForegroundColor Yellow }
    }
}

$dupes = $jarSeen.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }
if ($dupes) {
    Write-Host ""
    Write-Host "DUPLICATE jar referenced by several metafiles:" -ForegroundColor Red
    foreach ($d in $dupes) { Write-Host ("  {0}  <-  {1}" -f $d.Key, ($d.Value -join ", ")) }
}

if ($defaulted.Count -gt 0) {
    Write-Host ""
    Write-Host "Defaulted to 'both' ($($defaulted.Count)) -- review if any of these" -ForegroundColor DarkGray
    Write-Host "are actually client- or server-only, then add them to the lists:" -ForegroundColor DarkGray
    $defaulted | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

if ($DryRun) { Write-Host "`nDry run -- nothing was written." -ForegroundColor Magenta }
else { Write-Host "`nNow run: packwiz refresh" -ForegroundColor Green }
