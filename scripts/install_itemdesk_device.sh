#!/bin/zsh
set -euo pipefail

project_root="${ITEMDESK_PROJECT_ROOT:-$PWD}"
build_dir="${ITEMDESK_BUILD_DIR:-/tmp/itemdesk-device-install/build}"
install_dir="${ITEMDESK_INSTALL_DIR:-/tmp/itemdesk-device-install}"
app_path="${ITEMDESK_APP_PATH:-$build_dir/Build/Products/Debug-iphoneos/ItemDesk.app}"
device_name="${ITEMDESK_DEVICE_NAME:-}"
device_udid="${ITEMDESK_DEVICE_UDID:-}"
install_timeout="${ITEMDESK_INSTALL_TIMEOUT:-120}"
force_build="${ITEMDESK_FORCE_BUILD:-0}"
use_xcode_device_destination="${ITEMDESK_XCODE_DEVICE_DESTINATION:-0}"
discovery_attempts="${ITEMDESK_DEVICE_DISCOVERY_ATTEMPTS:-5}"
discovery_delay="${ITEMDESK_DEVICE_DISCOVERY_DELAY:-4}"

mkdir -p "$install_dir/logs"
cd "$project_root"

resolve_device_udid() {
  local device_listing="$1"
  local device_line=""

  if [[ -n "$device_udid" ]]; then
    return 0
  fi

  if [[ -n "$device_name" ]]; then
    device_line="$(rg -F "$device_name" "$device_listing" | rg 'physical' | head -n 1 || true)"
  else
    local available_devices
    available_devices="$(rg 'physical' "$device_listing" | rg 'connected|available \(paired\)' || true)"
    local device_count
    device_count="$(printf '%s' "$available_devices" | awk 'NF { count++ } END { print count+0 }')"
    if [[ "$device_count" != "1" ]]; then
      echo "ERROR: Found $device_count available physical devices. Set ITEMDESK_DEVICE_NAME or ITEMDESK_DEVICE_UDID to select the target. See $device_listing" >&2
      return 1
    fi
    device_line="$available_devices"
  fi

  device_udid="$(printf '%s\n' "$device_line" | sed -nE 's/.* ([0-9A-F-]{20,}) \(UDID\).*/\1/p')"
  if [[ -z "$device_udid" ]]; then
    echo "ERROR: Could not resolve an available physical iPhone. Set ITEMDESK_DEVICE_NAME or ITEMDESK_DEVICE_UDID. See $device_listing" >&2
    return 1
  fi
}

echo "ItemDesk project: $project_root"
echo "Working tree:"
git status --short || true

if [[ "$use_xcode_device_destination" == "1" ]]; then
  device_listing="$install_dir/devices-before-build.txt"
  xcrun devicectl list devices > "$device_listing"
  resolve_device_udid "$device_listing"
fi

if [[ "$force_build" == "1" || ! -d "$app_path" ]]; then
  build_log="$install_dir/build.log"
  echo "Building signed iOS app: $build_log"
  build_destination='generic/platform=iOS'
  if [[ "$use_xcode_device_destination" == "1" ]]; then
    build_destination="platform=iOS,id=$device_udid"
  fi
  xcodebuild build \
    -project ItemDesk.xcodeproj \
    -scheme ItemDesk \
    -destination "$build_destination" \
    -derivedDataPath "$build_dir" \
    -allowProvisioningUpdates > "$build_log" 2>&1
else
  echo "Reusing app bundle: $app_path"
fi

if [[ ! -d "$app_path" ]]; then
  echo "ERROR: ItemDesk.app was not found at $app_path" >&2
  exit 1
fi

device_listing="$install_dir/devices-before-install.txt"
xcrun devicectl list devices > "$device_listing"
resolve_device_udid "$device_listing"

refresh_device_listing() {
  local attempt=1
  while (( attempt <= discovery_attempts )); do
    xcrun devicectl list devices > "$device_listing"
    if rg -F "$device_udid" "$device_listing" | rg -q 'physical.*(connected|available \(paired\))|(connected|available \(paired\)).*physical'; then
      return 0
    fi
    if (( attempt < discovery_attempts )); then
      sleep "$discovery_delay"
    fi
    (( attempt++ ))
  done
  return 1
}

if ! refresh_device_listing; then
  echo "ERROR: Device $device_udid is not reported as connected or LAN-paired after $discovery_attempts discovery attempts. See $device_listing" >&2
  exit 1
fi

install_once() {
  local suffix="$1"
  local log_path="$install_dir/logs/install${suffix}.log"
  local json_path="$install_dir/install${suffix}.json"
  echo "Installing to ${device_name:-selected iPhone} ($device_udid): $log_path"
  if xcrun devicectl device install app \
      --device "$device_udid" \
      "$app_path" \
      --timeout "$install_timeout" \
      --json-output "$json_path" > "$log_path" 2>&1; then
    if rg -q '"outcome"[[:space:]]*:[[:space:]]*"success"' "$json_path"; then
      echo "Install succeeded. Result: $json_path"
      return 0
    fi
  fi
  echo "Install attempt failed. Log: $log_path" >&2
  return 1
}

if install_once '-attempt-1'; then
  exit 0
fi

if rg -qi '4016|fully initialize|coredeviceservice|timed out' "$install_dir/logs/install-attempt-1.log"; then
  echo "CoreDevice initialization failed; refreshing device list and retrying once."
  sleep 2
  xcrun devicectl list devices > "$install_dir/devices-before-retry.txt" 2>&1 || true
  install_once '-attempt-2' && exit 0
fi

echo "ERROR: ItemDesk installation failed after the bounded retry. Keep the iPhone unlocked and connected by USB or the same LAN, then inspect $install_dir/logs." >&2
exit 1
