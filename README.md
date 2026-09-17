# Ambient Weather HUD

An [Omarchy](https://omarchy.org/) shell plugin that shows live conditions
from a single [Ambient Weather](https://ambientweather.net/) personal
weather station: current temperature, feels-like, humidity, daily rain, and
wind, right in the bar. Colors and fonts always follow whatever Omarchy
theme is active — nothing is hardcoded.

## What you need

Two credentials from your ambientweather.net account (**Account → API
Keys**), both self-service, free to create:

- an **API key** (account-scoped)
- an **application key** (also self-generated on the same page)

You'll paste both into the plugin's setup screen the first time you open it;
it uses them to list your devices so you can pick the one station to track.

## Install

```bash
omarchy plugin add https://github.com/<you>/ambient-weather-hud.git --enable --yes
```

Or by hand:

```bash
git clone https://github.com/<you>/ambient-weather-hud.git ~/.config/omarchy/plugins/ambient-weather-hud
omarchy-shell shell rescanPlugins
omarchy plugin enable ambient-weather-hud
```

Then place it in the bar (it defaults to the right section):

```bash
omarchy bar move ambient-weather-hud --section right
```

## First run

Click the pill — it opens straight into setup the first time. Paste your API
key and application key, click **Find devices**, and pick your station. The
panel then shows live conditions and refreshes every 5 minutes (configurable
via the `refreshMinutes` setting on the widget's `shell.json` entry, 1–60).

To switch stations or rotate keys later, click the ⚙ next to the station
name in the panel.

## Where things live

- `~/.local/state/omarchy/settings/ambient-weather-hud.json` — your saved
  API key, application key, and selected device, written only by
  `bin/ambient-weather-hud-config` and kept at `chmod 600`.
- Bar pill + settings: `~/.config/omarchy/shell.json` (`refreshMinutes`),
  edited via `omarchy bar ...` like any other widget.

## Notes

- Ambient Weather's API returns Imperial units (°F, mph, in) only.
- Station uplinks typically only update every 1–5 minutes, so polling much
  faster than the default doesn't get you fresher data — it just adds load.
- Indoor-only stations (no outdoor sensor array) fall back to the indoor
  temperature/humidity/feels-like fields automatically.
