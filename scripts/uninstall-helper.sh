#!/bin/bash
# Removes the IzMac charge control helper and restores normal charging. Run: sudo scripts/uninstall-helper.sh
set -u
if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

LABEL="my.mfaizzz.izmac.helper"
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT="/Library/Application Support/IzMac"

[ -x "$BIN" ] && "$BIN" --restore
/bin/launchctl bootout "system/$LABEL" 2>/dev/null
/bin/rm -f "$PLIST" "$BIN"
/bin/rm -rf "$SUPPORT"
echo "IzMac helper removed. Charging, adapter and MagSafe LED are back under macOS control."
echo "The log /Library/Logs/IzMac-helper.log was left in place."
