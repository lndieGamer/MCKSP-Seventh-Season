<#
    apply-preserve.ps1 -- re-applies preserve = true to personal config files
    in index.toml.

    packwiz refresh rewrites index.toml and may drop manually added flags,
    so run this AFTER every refresh (the GitHub Action does the same thing).

        packwiz refresh
        powershell -ExecutionPolicy Bypass -File .\apply-preserve.ps1
#>

param([string]$Index = "index.toml", [switch]$DryRun)

$preserve = @(
    "config/DistantHorizons.toml"
    "config/MouseTweaks.cfg"
    "config/NoChatReports/NCR-Client.json"
    "config/NoChatReports/NCR-ServerPreferences.json"
    "config/aeroworks-client.toml"
    "config/alexscaves-client.toml"
    "config/ambientsounds-client.json"
    "config/amendments-client.toml"
    "config/appleskin-client.toml"
    "config/azimuth-client.toml"
    "config/betteradvancements-client.toml"
    "config/betterpingdisplay-client.toml"
    "config/carbonconfig.cfg"
    "config/carryon-client.toml"
    "config/computercraft-client.toml"
    "config/copycats-client.toml"
    "config/cosmeticarmorreworked-client.toml"
    "config/create-client.toml"
    "config/create_dragons_plus-client.toml"
    "config/create_enchantment_industry-client.toml"
    "config/create_radar-client.toml"
    "config/createbigcannons-client.toml"
    "config/createdieselgenerators-client.toml"
    "config/createpropulsion-client.toml"
    "config/createthrusters-client.toml"
    "config/creativecore-client.json"
    "config/cubes_without_borders.json"
    "config/curios-client.toml"
    "config/dndesires-client.toml"
    "config/doggytalents-client.toml"
    "config/dummmmmmy-client.toml"
    "config/enchdesc.json"
    "config/entity_model_features.json"
    "config/entity_texture_features.json"
    "config/entityculling.json"
    "config/fancymenu/options.txt"
    "config/farmersdelight-client.toml"
    "config/fastsuite.cfg"
    "config/flywheel-client.toml"
    "config/framedblocks-client.toml"
    "config/fzzy_config/keybinds.toml"
    "config/immersive_paintings/client_config.toml"
    "config/immersive_paintings/common_config.toml"
    "config/iris-excluded.json"
    "config/iris.properties"
    "config/jade/hide-blocks.json"
    "config/jade/hide-entities.json"
    "config/jade/jade.json"
    "config/jade/plugins.json"
    "config/jade/sort-order.json"
    "config/jei/blacklist.json"
    "config/jei/ingredient-list-mod-sort-order.ini"
    "config/jei/ingredient-list-type-sort-order.ini"
    "config/jei/jei-client.ini"
    "config/jei/jei-colors.ini"
    "config/jei/jei-debug.ini"
    "config/jei/jei-mod-id-format.ini"
    "config/jei/recipe-category-sort-order.ini"
    "config/justzoom/config.txt"
    "config/kiwi-client.yaml"
    "config/legendarytooltips.toml"
    "config/lithium.properties"
    "config/lodestone-client.toml"
    "config/lootr-client.toml"
    "config/modernfix-mixins.properties"
    "config/moonlight-client.toml"
    "config/moreoverlays.toml"
    "config/neoforge-client.toml"
    "config/ntgl-client.toml"
    "config/particlerain/config.json"
    "config/pipeorgans-client.toml"
    "config/placebo.cfg"
    "config/ponder-client.toml"
    "config/powergrid-client.toml"
    "config/pregen/base.cfg"
    "config/pregen/map-client.cfg"
    "config/pregen/map-common.cfg"
    "config/pregen/minimap.cfg"
    "config/railways-client.toml"
    "config/sable-client.toml"
    "config/sablejade-client.toml"
    "config/simulated-client.toml"
    "config/skinlayers.json"
    "config/sliceanddice-client.toml"
    "config/snowrealmagic-client.yaml"
    "config/sodium-extra-options.json"
    "config/sodium-extra.properties"
    "config/sodium-mixins.properties"
    "config/sodium-options.json"
    "config/sophisticatedcore-client.toml"
    "config/storagedrawers-client.toml"
    "config/trade_cycling-client.toml"
    "config/trmt-client.json"
    "config/waves/waves.json"
    "config/worldedit/worldedit.properties"
    "config/xaero/lib/client.cfg"
    "config/xaero/lib/common.cfg"
    "config/xaero/lib/profiles/default.cfg"
    "config/xaero/lib/server_profiles/default.cfg"
    "config/xaero/minimap/client.cfg"
    "config/xaero/minimap/common.cfg"
    "config/xaero/minimap/default_radar_categories_client.json"
    "config/xaero/minimap/default_radar_categories_server.json"
    "config/xaero/minimap/profiles/default.cfg"
    "config/xaero/minimap/server_profiles/default.cfg"
    "config/xaero/world-map/client.cfg"
    "config/xaero/world-map/common.cfg"
    "config/xaero/world-map/profiles/default.cfg"
    "config/xaero/world-map/server_profiles/default.cfg"
    "config/xaerohud.txt"
    "options.txt"
    "servers.dat"
)

if (-not (Test-Path $Index)) {
    Write-Host "index.toml not found. Run this from the pack root." -ForegroundColor Red
    exit 1
}

$text  = Get-Content -Path $Index -Raw -Encoding UTF8
$added = 0; $already = 0; $absent = @()

foreach ($f in $preserve) {
    $esc = [regex]::Escape($f)
    # each entry looks like:  [[files]]\nfile = "..."\nhash = "..."
    $rx = "(?ms)(\[\[files\]\]\s*\r?\nfile\s*=\s*""$esc""\r?\n)((?:(?!\[\[files\]\]).)*?)(?=\r?\n\[\[files\]\]|\z)"
    $m = [regex]::Match($text, $rx)
    if (-not $m.Success) { $absent += $f; continue }
    if ($m.Groups[2].Value -match '(?m)^preserve\s*=') { $already++; continue }
    $replacement = $m.Groups[1].Value + "preserve = true`n" + $m.Groups[2].Value
    $text = $text.Remove($m.Index, $m.Length).Insert($m.Index, $replacement)
    $added++
}

if (-not $DryRun -and $added -gt 0) {
    [System.IO.File]::WriteAllText((Resolve-Path $Index), $text, (New-Object System.Text.UTF8Encoding $false))
}

Write-Host ""
Write-Host "preserve added: $added   already set: $already" -ForegroundColor Cyan
if ($absent.Count -gt 0) {
    Write-Host ""
    Write-Host "Not present in index ($($absent.Count)) -- normal if you did not ship these:" -ForegroundColor DarkGray
    $absent | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
if ($DryRun) { Write-Host "`nDry run -- nothing was written." -ForegroundColor Magenta }
