# AirNow → Slack Air Quality Updater

Scheduled PowerShell script that pulls current AQI from the EPA AirNow API for two street addresses and posts a formatted summary to a Slack channel via an incoming webhook, on a 45-minute rotation driven by Windows Task Scheduler. Designed and iterated in Claude chat; this file is the handoff context for the script, which lives beside it as `airnow-slack.ps1`.

## Architecture / flow

- Config: two locations defined by full US street address in the `$Locations` block at the top of the script.
- Geocoding: addresses → US Census geocoder (free, no API key) → lat/long. Results cached to `geocode-cache.json` beside the script, so only the first run per address hits the geocoder.
- Data: lat/long → AirNow current-observations endpoint. Returns one JSON entry per pollutant (PM2.5, O3, etc.), each with AQI and category name.
- Formatting: worst-AQI pollutant is the headline per location, remaining pollutants listed as detail; category name maps to a colored Slack emoji.
- Delivery: single combined message POSTed to a Slack incoming webhook as a plain `{"text": "..."}` payload (Slack mrkdwn formatting).

## Configuration and secrets

- `AIRNOW_API_KEY` and `SLACK_WEBHOOK_URL` are read from user-scope environment variables, set via `[Environment]::SetEnvironmentVariable(<name>, <value>, 'User')` so the scheduled task (running as the same user) can see them.
- The webhook URL is a credential — anyone holding it can post to the channel. Never commit it or hardcode it in the script.

## External services

- AirNow: `https://www.airnowapi.org/aq/observation/latLong/current/?format=application/json&latitude=..&longitude=..&distance=25&API_KEY=..` — key from docs.airnowapi.org. Rate limit 500 req/hr; this project uses 2 per run.
- Census geocoder: `https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?address=..&benchmark=Public_AR_Current&format=json` — gotcha: response coordinates are `x` = longitude, `y` = latitude.
- Slack incoming webhook: created at api.slack.com/apps → Incoming Webhooks → Add New Webhook to Workspace.

## Scheduling (Windows Task Scheduler)

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
           -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\airnow-slack.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
           -RepetitionInterval (New-TimeSpan -Minutes 45)
Register-ScheduledTask -TaskName 'AirNow Slack Update' -Action $action -Trigger $trigger
```

If an earlier (hourly) version of the task is already registered, replace the trigger in place: `Set-ScheduledTask -TaskName 'AirNow Slack Update' -Trigger $trigger`.

## Known behavior / open items

- AirNow observations refresh only once per hour (typically ~30–45 min past the hour). The 45-minute cadence therefore reposts identical readings on some cycles, and post times drift around the clock (:00, :45, 1:30, 2:15 ... realigning every 3 hours). This is accepted for now.
- Discussed but not yet built: a skip-if-unchanged check — cache each location's last posted `DateObserved`/`HourObserved` and suppress the Slack post when nothing is new.
- AirNow reports AQI = -1 when a monitor has no value for a pollutant; the max-AQI headline logic tolerates this in practice.
- `distance=25` (miles) is the AirNow search radius — widen it if an address comes back with no monitoring data.
- Geocode and fetch failures degrade gracefully: the message still posts, with an error line for the affected location.

## Environment constraints

- Target: Windows PowerShell 5.1+ (also runs on PowerShell 7). No external modules — `Invoke-RestMethod` only.
- `$PSScriptRoot` is used for the cache path, so the script must run via `-File`, not pasted into a console.
