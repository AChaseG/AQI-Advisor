# AirNow -> Slack air quality update (45-min schedule)
# Locations are configured by street address. Addresses are geocoded once via
# the free US Census geocoder, then cached locally so later runs skip the lookup.

$ApiKey     = $env:AIRNOW_API_KEY
$WebhookUrl = $env:SLACK_WEBHOOK_URL

# Set your two locations here (full US street addresses)
$Locations = @(
    @{ Name = 'Home';   Address = '400 Broad St, Seattle, WA 98109' }
    @{ Name = 'Office'; Address = '85 Pike St, Seattle, WA 98101' }
)

$CategoryEmoji = @{
    'Good'                           = ':large_green_circle:'
    'Moderate'                       = ':large_yellow_circle:'
    'Unhealthy for Sensitive Groups' = ':large_orange_circle:'
    'Unhealthy'                      = ':red_circle:'
    'Very Unhealthy'                 = ':large_purple_circle:'
    'Hazardous'                      = ':black_circle:'
}

# --- geocoding with local cache ---------------------------------------------
$CacheFile = Join-Path $PSScriptRoot 'geocode-cache.json'
$Cache = @{}
if (Test-Path $CacheFile) {
    (Get-Content $CacheFile -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $Cache[$_.Name] = $_.Value }
}

function Get-Coordinates([string]$Address) {
    if ($Cache.ContainsKey($Address)) { return $Cache[$Address] }

    $uri = 'https://geocoding.geo.census.gov/geocoder/locations/onelineaddress' +
           "?address=$([uri]::EscapeDataString($Address))" +
           '&benchmark=Public_AR_Current&format=json'
    try   { $result = Invoke-RestMethod -Uri $uri -TimeoutSec 30 }
    catch { return $null }

    $match = $result.result.addressMatches | Select-Object -First 1
    if (-not $match) { return $null }

    # Census returns x = longitude, y = latitude
    $coords = @{ Lat = $match.coordinates.y; Lon = $match.coordinates.x }
    $Cache[$Address] = $coords
    $Cache | ConvertTo-Json -Depth 5 | Set-Content $CacheFile
    return $coords
}

# --- fetch + format ----------------------------------------------------------
$lines = foreach ($loc in $Locations) {
    $coords = Get-Coordinates $loc.Address
    if (-not $coords) {
        "*$($loc.Name)*: couldn't geocode '$($loc.Address)'"
        continue
    }

    $uri = 'https://www.airnowapi.org/aq/observation/latLong/current/' +
           "?format=application/json&latitude=$($coords.Lat)&longitude=$($coords.Lon)" +
           "&distance=25&API_KEY=$ApiKey"
    try {
        $obs = @(Invoke-RestMethod -Uri $uri -TimeoutSec 30)
    }
    catch {
        "*$($loc.Name)*: fetch failed - $($_.Exception.Message)"
        continue
    }

    if ($obs.Count -eq 0) {
        "*$($loc.Name)*: no monitoring data near this address"
        continue
    }

    # AirNow returns one entry per pollutant - headline the worst AQI
    $worst  = $obs | Sort-Object AQI -Descending | Select-Object -First 1
    $emoji  = $CategoryEmoji[$worst.Category.Name]
    $detail = ($obs | ForEach-Object { "$($_.ParameterName) $($_.AQI)" }) -join ', '
    "$emoji *$($loc.Name)* ($($worst.ReportingArea)): AQI $($worst.AQI) - $($worst.Category.Name)  [$detail]"
}

$payload = @{
    text = "*Air Quality Update* - $(Get-Date -Format 'MMM d, h:mm tt')`n" + ($lines -join "`n")
} | ConvertTo-Json

Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $payload | Out-Null
