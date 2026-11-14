# IzMac

A small native macOS menu bar app (SwiftUI, macOS 14+). The menu bar shows something like `Cx 100% · Cl 82% · Asar 4:22 PM`: Codex 5h remaining, Claude 5h remaining, next prayer. Click it for the details.

## Features

- **A moment of reflection**: a short English or Bahasa Melayu reminder, random each time the popover opens.
- **Waktu solat**: Imsak to Isyak for your zone (default WLY01, Kuala Lumpur; auto-picked from location if allowed), Hijri date, next prayer countdown. Last response is cached in `~/Library/Application Support/IzMac/solat.json` so times show offline.
- **Codex usage**: 5h and weekly remaining with reset times, all-time and peak daily tokens, and the latest day's tokens, as reported by the Codex app-server (same numbers as the old Codex Usage app).
- **Claude usage**: 5h and weekly remaining from Claude Code's login.
- **Battery** (read-only): charge, state, cycles, max capacity (% and mAh vs design), temperature, condition. No charge limiting in v0.1.
- Refresh now (Cmd-R), Launch at login, Quit (Cmd-Q). Refreshes every 60s (Claude every 5 min) and when opened.

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

Data from JAKIM e-Solat via the waktusolat.app API (mptwaktusolat). Field shapes cross-checked against open-source projects such as steipete/CodexBar and others that read the same files and endpoint. Inspired by AlDente.

## License

GPL-3.0-or-later. The `LICENSE` file holds the standard short notice and a pointer to the full text at https://www.gnu.org/licenses/gpl-3.0.txt, not the full license text.
