#!/bin/bash
set -e

osascript -e 'quit app "NotNow"' 2>/dev/null || true
sleep 0.5

rm -rf /Applications/NotNow.app
cp -rf "$(dirname "$0")/build/export/NotNow.app" /Applications/NotNow.app

echo "==> Installed to /Applications/NotNow.app"
