# IzMac

A small native macOS menu bar app (SwiftUI, macOS 14+). The menu bar shows something like `Cx 100% · Cl 82% · Asar 4:22 PM`: Codex 5h remaining, Claude 5h remaining, next prayer. Click it for the details.

## Features

- **A moment of reflection**: a short English or Bahasa Melayu reminder, random each time the popover opens.
- **Waktu solat**: Imsak to Isyak for your zone (default WLY01, Kuala Lumpur; auto-picked from location if allowed), Hijri date, next prayer countdown. Last response is cached in `~/Library/Application Support/IzMac/solat.json` so times show offline.
- **Codex usage**: 5h and weekly remaining with reset times, all-time and peak daily tokens, and the latest day's tokens, as reported by the Codex app-server (same numbers as the old Codex Usage app).
- **Claude usage**: 5h and weekly remaining from Claude Code's login.
- **Battery**: charge, state, cycles, max capacity (% and mAh vs design), temperature, condition, plus charge control (see below) and 24 h charts in the IzMac window.
- Refresh now (Cmd-R), Open IzMac… (the window), Launch at login, Quit (Cmd-Q). Refreshes every 60s (Claude every 5 min) and when opened.
- **IzMac window** (popover footer, "Open IzMac…"): Dashboard (level, temperature and power charts for 24 h, health, adapter watts), Charge Control, Sleep Behaviour, Energy Use, Schedule, Appearance (which parts the menu bar shows, MagSafe LED, launch at login). Samples are taken every 60 s and kept 48 h in `~/Library/Application Support/IzMac/history.json`.

## Charge control

Apple Silicon only (arm64, macOS 14+; developed against macOS 26). Intel is out of scope.

**Warning.** Charging is controlled by writing undocumented SMC keys as root. Apple can change or gate them in any macOS or firmware update (the batt project reports that macOS 27 developer betas started refusing these writes). If a key is missing or its size is unexpected, IzMac never writes it and reports the feature as unsupported. Turn off macOS's own charge limit and Optimised Battery Charging (System Settings > Battery) so the two do not fight.

### Features (Charge Control, Sleep Behaviour, Energy Use, Schedule, Appearance)

- **Charge limit** 20-100 % (default 80). Charging stops at the limit and resumes just below it.
- **Sailing mode**: after reaching the limit, charging does not resume until the level drops by the sailing range (2-20 %, default 5).
- **Discharge**: run on battery while plugged in until the limit is reached. **Automatic discharge** does that whenever you are plugged in above the limit. The helper never force-discharges at 10 % or below.
- **Top Up**: charge to 100 % once; clears itself at 100 % or when you unplug.
- **Heat protection**: pause charging at a battery temperature of 30-45 °C or higher (default 35), resume 2 °C below.
- **Calibration**: charge to 100, discharge to 10, charge to 100, hold 1 hour, discharge to the limit, then back to normal. Shows the step, can be cancelled, remembers the last date. It lives in the helper's memory, so a helper restart (reboot) cancels it.
- **Sleep**: "Prevent sleep while charging to the limit" (the app holds an IOPMAssertion while charging below the target, or while discharging above the "allow sleep again at N %" floor) and "Stop charging before sleep" (the helper registers with IORegisterForSystemPower and stops charging before sleep when at or above the target, then re-checks on wake).
- **MagSafe LED**: system / reflect charge limit (green at the limit, orange while charging) / the same plus slow orange blink while discharging / off.
- **Schedule**: tasks (set limit N, Top Up, start discharge, start calibration) at a time of day on chosen weekdays, evaluated by the helper. "Catch up" runs tasks missed while asleep within the last 6 hours. The last 20 runs are listed. A scheduled limit lasts until you change the limit yourself.
- **Low Power Mode**: leave to macOS / never / always / only on battery / only on power adapter, applied with `/usr/bin/pmset -b|-c lowpowermode` only when you change the setting.

Not included: Apple Shortcuts actions (they need an App Intents build step in Xcode), the "apps using significant energy" list, the hardware battery percentage toggle, and Intel support.

### Enable, disable, uninstall

- **Enable**: click "Enable charge control" in the popover or the window. macOS shows its own admin password prompt once (via `osascript`; IzMac never sees the password). It copies the app's executable to `/Library/PrivilegedHelperTools/my.mfaizzz.izmac.helper` (root:wheel 755, not run from the user-writable app bundle), writes `/Library/LaunchDaemons/my.mfaizzz.izmac.helper.plist` (root:wheel 644, RunAtLoad, KeepAlive, runs `IzMac --daemon`), creates `/Library/Application Support/IzMac/` (writable by you) and bootstraps the daemon with `launchctl bootstrap system`.
- **Update**: when the app version differs from the helper's (shown in `state.json`), "Update helper" appears and reruns the installer.
- **Disable**: "Disable charge control" in the window (or `sudo scripts/uninstall-helper.sh` from Terminal) restores charging, the adapter and the MagSafe LED (`IzMac --restore`), boots the daemon out and deletes the helper, plist and support directory. The log stays.
- Files: helper `/Library/PrivilegedHelperTools/my.mfaizzz.izmac.helper`, plist `/Library/LaunchDaemons/my.mfaizzz.izmac.helper.plist`, config `/Library/Application Support/IzMac/config.json` (app writes, helper re-reads every 2 s), state `/Library/Application Support/IzMac/state.json` (helper writes), log `/Library/Logs/IzMac-helper.log` (rotated at 1 MB).
- **Fail-safe**: on SIGTERM/SIGINT, on uninstall, and whenever control is off or `config.json` is missing or invalid, the helper re-enables charging and the adapter and gives the LED back to the system. The config is treated as untrusted: strict decoding, every number clamped, unknown fields ignored.

### SMC keys used and where they come from

Which keys exist is probed at startup (size must match, otherwise the feature is unsupported). Values were checked against the reference code, and where the projects disagree I say so.

| Function | Key (type) | Normal / active value | Source |
| --- | --- | --- | --- |
| Charging inhibit, newer firmware (tried first) | `CHTE` (ui32, 4 bytes) | `00 00 00 00` normal, `01 00 00 00` inhibited | Battery-Toolkit, OpenDente, batt |
| Charging inhibit, older firmware | `CH0B` + `CH0C` (1 byte each) | `00` normal, `02` inhibited (both keys) | OpenDente, battery, batt. Battery-Toolkit instead uses `CH0C` alone with `01`; I followed the three that agree |
| Adapter disable (force discharge) | `CHIE` (1 byte) | `00` normal, `08` disabled | Battery-Toolkit, OpenDente, batt |
| | `CH0I` (1 byte) | `00` normal, `01` disabled | OpenDente, battery, batt |
| | `CH0J` (1 byte) | `00` normal, `20` disabled | Battery-Toolkit (batt writes `01` here; unverified which is right) |
| MagSafe LED | `ACLC` (ui8) | `00` system, `01` off, `03` green, `04` orange, `06` orange slow blink | Battery-Toolkit, OpenDente (all but `06`), batt |
| Adapter connected | `AC-W` (int8, > 0) | read only, used because macOS may report "not plugged in" while the adapter is disabled | batt (key name only) |

Discharging writes the adapter key and also inhibits charging, as OpenDente does. Battery temperature is not read from the SMC: IzMac uses the `Temperature` property of `AppleSmartBattery` in the IORegistry (OpenDente reads `TB0T`, a float, with `B0AT` as fallback, but the registry value is the same sensor and needs no key decoding). The macOS 27 firmware keys `bfF0`/`bfD0`/`bfE0` seen in batt are not used.

## Install

CI builds `IzMac.zip` on every push to main (Actions artifact). Download and unzip it, then:

    mv IzMac.app /Applications/ && xattr -dr com.apple.quarantine /Applications/IzMac.app && open /Applications/IzMac.app

Or build locally on a Mac with Xcode: `scripts/bundle.sh && scripts/install.sh` (produces `build/IzMac.app` and `build/IzMac.zip`, ad-hoc signed). Tests: `swift test`.

## Data sources

- **Prayer times and zone**: `https://api.waktusolat.app/v2/solat/{zone}` (a month of times as unix timestamps, with Hijri dates; data originates from JAKIM e-Solat) and `https://api.waktusolat.app/v2/solat/gps/{lat}/{long}` which returns the same shape for the nearest zone. I chose this single source over calling JAKIM directly because one request gives times, Hijri date and zone-from-GPS in one stable JSON shape with no time-string parsing. Trade-off: it is a third-party mirror of JAKIM.
- **Codex**: runs `codex app-server --stdio` (from the ChatGPT app's bundled CLI, else `/opt/homebrew/bin/codex`, `/usr/local/bin/codex` or `~/.local/bin/codex`) and calls `account/rateLimits/read` and `account/usage/read` over newline-delimited JSON, with a 35 s deadline; the child is always terminated. Uses your existing Codex sign-in. If no Codex binary is found, it falls back to the local rollout files `~/.codex/sessions/**/*.jsonl` (`token_count` events carry `rate_limits` and `info.total_token_usage.total_tokens`), where "yesterday" replaces the latest-day line.
- **Claude**: `GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token (Keychain item `Claude Code-credentials`, fallback `~/.claude/.credentials.json`). This is an undocumented endpoint and may change. If it says "Run /login in Claude Code", log in there.
- **Battery**: IOKit `AppleSmartBattery`. "Condition" is derived (Normal if max capacity is 80% or more), as macOS does not expose it in the registry.

## Replacing Codex Usage

The old app lives at `~/Documents/Codex/2026-09-26/check-token-info-n-make-as/outputs/Codex Usage.app` and is started at login by a LaunchAgent labelled `local.codex.usage-menubar`. Once IzMac's Codex numbers match it, decommission it:

    launchctl bootout gui/$(id -u)/local.codex.usage-menubar
    rm ~/Library/LaunchAgents/local.codex.usage-menubar.plist

Then quit the app if it is still running.

## Privacy

Everything is local. The only network calls are to api.waktusolat.app (prayer times; your coordinates are sent only if you allow location) and api.anthropic.com (usage, using your existing Claude Code token, which is never logged or stored by IzMac). The Codex numbers come from the local Codex app-server, which talks to OpenAI using your existing sign-in; IzMac itself sends nothing.

## Credits

Charge control: SMC client layout, key names and byte values learned from and partly adapted from OpenDente (killerk3emstar, GPL-3.0), Battery-Toolkit (Marvin Häuser, BSD-3-Clause), battery (Mentor Palokaj, MIT) and, for key names only, batt (charlie0129, GPL-2.0, no code copied). See `NOTICE` for the license notices.

Data from JAKIM e-Solat via the waktusolat.app API (mptwaktusolat). Field shapes cross-checked against open-source projects such as steipete/CodexBar and others that read the same files and endpoint. Inspired by AlDente.

## License

GPL-3.0-or-later. The `LICENSE` file holds the standard short notice and a pointer to the full text at https://www.gnu.org/licenses/gpl-3.0.txt, not the full license text.
