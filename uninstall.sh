#!/bin/sh
# Removes what install.sh put in place. Leaves Homebrew's sane-backends (brew uninstall sane-backends)
# and the project folder alone.
DOMAIN="gui/$(id -u)"
for label in z300bridge.app z300bridge.airsaned; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf "/Applications/Z300 Scan.app" "$HOME/Library/Application Support/z300-bridge" "$HOME/Library/Logs/z300-bridge"
defaults delete z300bridge.scan 2>/dev/null
echo "uninstalled"
