#!/bin/sh
# Builds and installs, for the current user:
#   /Applications/Z300 Scan.app                      menu-bar app: insert a sheet, choose, scan to the Desktop
#   ~/Library/Application Support/z300-bridge/       AirSane + the SANE driver, so Preview/Image Capture can scan
#   ~/Library/LaunchAgents/z300bridge.*              start both at login, restart them if they crash
# Needs Homebrew's sane-backends. Undo with ./uninstall.sh.
set -e
cd "$(dirname "$0")"
SUPPORT="$HOME/Library/Application Support/z300-bridge"
LOGS="$HOME/Library/Logs/z300-bridge"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

(cd backend && make -s)
[ -f AirSane/CMakeLists.txt ] || git submodule update --init AirSane
[ -d AirSane-build ] || cmake -S AirSane -B AirSane-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/homebrew >/dev/null
(cd AirSane-build && make -s airsaned >/dev/null)
app/build.sh

mkdir -p "$SUPPORT/bin" "$SUPPORT/lib" "$SUPPORT/sane.d" "$SUPPORT/airsane" "$LOGS"
cp AirSane-build/airsaned "$SUPPORT/bin/"
cp backend/libsane-plustek_scanapi.1.so "$SUPPORT/lib/"
printf "plustek_scanapi\n" > "$SUPPORT/sane.d/dll.conf"
[ -f "$SUPPORT/sane.d/plustek_scanapi.conf" ] || sed 's/^first-page-wait .*/first-page-wait 60/' sane.d/plustek_scanapi.conf > "$SUPPORT/sane.d/plustek_scanapi.conf"
printf "allow 127.0.0.0/8\nallow ::1\n" > "$SUPPORT/airsane/access.conf"
touch "$SUPPORT/airsane/options.conf" "$SUPPORT/airsane/ignore.conf"
cat > "$SUPPORT/run-airsaned.sh" <<'RUN'
#!/bin/sh
# AirSane with the Plustek driver, reachable from this Mac only (loopback, access list).
# USB hotplug watching is off: Plustek's engine re-enumerates the scanner whenever it releases it.
cd "$(dirname "$0")"
export SANE_CONFIG_DIR="$PWD/sane.d" LD_LIBRARY_PATH="$PWD/lib" SANE_DEBUG_PLUSTEK_SCANAPI=1
exec bin/airsaned --interface=lo0 --listen-port=8090 --hotplug=false --network-hotplug=false \
  --local-scanners-only=true --disclose-version=false --options-file="$PWD/airsane/options.conf" \
  --ignore-list="$PWD/airsane/ignore.conf" --access-file="$PWD/airsane/access.conf"
RUN
chmod +x "$SUPPORT/run-airsaned.sh"

rm -rf "/Applications/Z300 Scan.app"
cp -R "app/build/Z300 Scan.app" /Applications/

agent() {   # label, KeepAlive xml, program arguments...
    label=$1 keepalive=$2; shift 2
    args=""; for a in "$@"; do args="$args<string>$a</string>"; done
    cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key><array>$args</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key>$keepalive
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>StandardOutPath</key><string>$LOGS/$label.log</string>
	<key>StandardErrorPath</key><string>$LOGS/$label.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    # bootout returns before the old process has exited (the app first releases the scanner)
    for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || break; sleep 1; done
    launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
}
# The app may be quit from its menu (clean exit stays quit); AirSane is always kept running.
agent z300bridge.airsaned "<true/>" "$SUPPORT/run-airsaned.sh"
agent z300bridge.app "<dict><key>SuccessfulExit</key><false/></dict>" "/Applications/Z300 Scan.app/Contents/MacOS/Z300 Scan"
echo "installed; logs in $LOGS"
