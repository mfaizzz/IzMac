#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

pkill -x IzMac 2>/dev/null || true
rm -rf /Applications/IzMac.app
cp -R build/IzMac.app /Applications/IzMac.app
xattr -dr com.apple.quarantine /Applications/IzMac.app
open /Applications/IzMac.app
