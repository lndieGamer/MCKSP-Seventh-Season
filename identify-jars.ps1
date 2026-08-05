<#
    identify-jars.ps1 -- identifies leftover .jar files via the Modrinth API.

    After "packwiz curseforge detect", unmatched mods stay as plain .jar files.
    This script hashes them (SHA-1) and asks Modrinth which project each one
    belongs to, then prints ready-to-run "packwiz modrinth add" commands.

    Run from the pack root (next to pack.toml):
        powershell -ExecutionPolicy Bypass -File .\identify-jars.ps1
#>

param([string]$ModsDir = "mods")

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = "packwiz-helper/1.0 (private modpack)"

$jars = Get-ChildItem -Path $ModsDir -Filter *.jar -ErrorAction SilentlyContinue
if (-not $jars) { Write-Host "No .jar files left in '$ModsDir' -- nothing to do." -ForegroundColor Green; exit }

Write-Host "Hashing $($jars.Count) file(s)..." -ForegroundColor Cyan
$byHash = @{}
foreach ($j in $jars) {
    $h = (Get-FileHash -Path $j.FullName -Algorithm SHA1).Hash.ToLower()
    $byHash[$h] = $j.Name
}

# --- bulk hash lookup -------------------------------------------------
$body = @{ hashes = @($byHash.Keys); algorithm = "sha1" } | ConvertTo-Json -Compress
try {
    $found = Invoke-RestMethod -Method Post -Uri "https://api.modrinth.com/v2/version_files" `
        -ContentType "application/json" -Headers @{ "User-Agent" = $UA } `
        -Body ([Text.Encoding]::UTF8.GetBytes($body))
} catch {
    Write-Host "Modrinth request failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# response is an object keyed by hash; PowerShell exposes it as NoteProperties
$hits = @{}
foreach ($p in $found.PSObject.Properties) { $hits[$p.Name.ToLower()] = $p.Value }

if ($hits.Count -eq 0) {
    Write-Host "Modrinth recognised none of these files." -ForegroundColor Yellow
} else {
    # --- resolve project ids to slugs ---------------------------------
    $ids = @($hits.Values | ForEach-Object { $_.project_id } | Sort-Object -Unique)
    $idsJson = ($ids | ConvertTo-Json -Compress)
    if ($ids.Count -eq 1) { $idsJson = "[$idsJson]" }   # single item is not an array
    $uri = "https://api.modrinth.com/v2/projects?ids=" + [Uri]::EscapeDataString($idsJson)
    $projects = Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = $UA }

    $slug = @{}
    foreach ($p in $projects) { $slug[$p.id] = $p.slug }

    Write-Host ""
    Write-Host "Recognised ($($hits.Count)) -- run these:" -ForegroundColor Green
    Write-Host ""
    foreach ($h in $hits.Keys) {
        $v = $hits[$h]
        $s = $slug[$v.project_id]
        $jar = $byHash[$h]
        $note = ""
        if ($v.version_number -and $jar -notmatch [regex]::Escape($v.version_number.Split('+')[0])) {
            $note = "   # latest on Modrinth: $($v.version_number)"
        }
        Write-Host "packwiz modrinth add $s$note"
        Write-Host "    # was: $jar" -ForegroundColor DarkGray
    }
}

# --- anything Modrinth did not know ----------------------------------
$missing = @($byHash.Keys | Where-Object { -not $hits.ContainsKey($_) } | ForEach-Object { $byHash[$_] })
if ($missing) {
    Write-Host ""
    Write-Host "Not on Modrinth ($($missing.Count)) -- these need a hand-written .pw.toml" -ForegroundColor Yellow
    Write-Host "and a copy uploaded to GitHub Releases:" -ForegroundColor Yellow
    $missing | Sort-Object | ForEach-Object { Write-Host "  $_" }
}

Write-Host ""
Write-Host "Delete each .jar only after its .pw.toml exists, then run: packwiz refresh" -ForegroundColor Cyan
