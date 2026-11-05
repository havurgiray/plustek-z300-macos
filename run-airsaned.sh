#!/bin/sh
# Starts AirSane with the Plustek driver, reachable from this Mac only.
# USB hotplug watching is off: Plustek's engine re-enumerates the scanner on every connect and release,
# which AirSane would otherwise take for a plug event and reload, mid-scan included.
cd "$(dirname "$0")"
export SANE_CONFIG_DIR="$PWD/sane.d" LD_LIBRARY_PATH="$PWD/backend" SANE_DEBUG_PLUSTEK_SCANAPI=1
exec AirSane-build/airsaned --interface=lo0 --listen-port=8090 --hotplug=false --network-hotplug=false \
  --local-scanners-only=true --options-file="$PWD/airsane-etc/options.conf" \
  --ignore-list="$PWD/airsane-etc/ignore.conf" --access-file="$PWD/airsane-etc/access.conf" "$@"
