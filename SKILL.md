---
name: iosapp-install
description: Build or reuse an Xcode iOS app and install it to a physical iPhone by USB, local network, or a configured remote OTA route, without erasing app data.
license: MIT
metadata:
  short-description: Install iOS apps by USB, LAN, or configured OTA
---

# iOSapp-install

Use this skill when the user asks to install the current iOS app build on a
physical iPhone. Resolve the requested target at runtime instead of assuming a
particular phone is connected. For remote mode, resolve the intended device
from its existing iOS OTA profile and pairing identity, not CoreDevice
availability.

## Choose the installation mode

| Mode | When to use | Installation path |
| --- | --- | --- |
| USB cable / 线缆安装 | User requests cable installation, or a verified USB connection is available | Xcode build, then CoreDevice install |
| Local network / 局域网安装 | User requests LAN installation, or a trusted phone is available on the same LAN | Xcode build, then CoreDevice install |
| Remote / 远程安装 | User requests remote/OTA installation, including an ongoing cellular test | Xcode build, then iOS OTA over Tailscale |

Honor the user's selected mode and ongoing session context. With no preference,
use a verified USB connection first, then available paired LAN, then an already
configured active OTA bridge. Ask only if the target or route remains ambiguous.
Do not silently change transport during a route-specific test. CoreDevice
`connected` alone does not prove USB; report only transport evidence observed.

For remote mode, read [references/remote-ota.md](references/remote-ota.md) and
skip the CoreDevice discovery/install sequence below. Tailscale connectivity
does not by itself prove Apple pairing or an active iOS OTA tunnel.

## Scope and safety

- Install only the app bundle. Never uninstall the app, erase its container,
  reset state, or launch with testing/reset arguments unless the user asks.
- Keep the current branch and working tree intact. Do not merge or push code as
  part of installation.
- A successful install is the only claim this skill makes. UI behavior needs a
  separate device verification request and the `device-interaction` skill.
- Keep command logs and the JSON result under `/tmp/itemdesk-device-install/`
  (or the path supplied by the caller) so failures are diagnosable.

## USB / LAN fast path

1. From the ItemDesk repository, check `git status --short` and locate a signed
   `ItemDesk.app`. Reuse an existing app bundle when its source/build context
   is known. Otherwise run:

   ```sh
   xcodebuild build -project ItemDesk.xcodeproj -scheme ItemDesk \
     -destination 'generic/platform=iOS' \
     -derivedDataPath /tmp/itemdesk-device-install/build \
     -allowProvisioningUpdates
   ```

2. Discover the physical target with `xcrun devicectl list devices`. Select
   the device explicitly named by the user or the only available physical
   device. For LAN installs, `available (paired)` is an acceptable CoreDevice
   state; do not substitute a simulator when the request is for an iPhone.

3. Install without deleting data:

   ```sh
   xcrun devicectl device install app \
     --device <UDID> \
     <path-to-ItemDesk.app> \
     --timeout 120 \
     --json-output /tmp/itemdesk-device-install/install.json
   ```

   Capture stdout/stderr in `/tmp/itemdesk-device-install/install.log`.

4. Treat the JSON `info.outcome == "success"` and the reported bundle ID
   `com.itemdesk.app` as the acceptance signal. Report the device name,
   outcome, install result path, and any CoreDevice error verbatim enough to be
   actionable.

## Xcode LAN route

When `devicectl` reports `available (paired)` and Xcode can see the phone,
confirm the network-aware destination first:

```sh
xcodebuild -showdestinations -project ItemDesk.xcodeproj -scheme ItemDesk
xcodebuild build -project ItemDesk.xcodeproj -scheme ItemDesk \
  -destination 'platform=iOS,id=<UDID>' \
  -derivedDataPath /tmp/itemdesk-xcode-lan/build \
  -allowProvisioningUpdates
```

Install the resulting `Debug-iphoneos/ItemDesk.app` with the same paired
CoreDevice target and retain both Xcode and install logs. This is the proven
LAN path for this project; `xcodebuild` provides the physical destination
build, while CoreDevice performs the final app write.

The phone can briefly disappear from CoreDevice while Xcode is finishing a
device build. Refresh the device list for a bounded window before installing;
when the already-built app is available, retry discovery/install without
rebuilding. Do not unpair or fall back to a simulator.

## Retry boundary

If the device is listed as `connected` or `available (paired)` but CoreDevice
returns error 4016 or `Timed out waiting for CoreDeviceService to fully
initialize`, wait briefly and retry the same install once after re-running
`xcrun devicectl list devices`.
If the device becomes `unavailable` after a successful build, refresh discovery
for the helper's bounded window and reuse the generated app when possible. Do
not loop indefinitely, unpair, or erase anything. If it still fails, stop and
tell the user to keep the iPhone unlocked and on the same LAN as the Mac, then
provide the log path. A cable-free installation is only reported as successful
after CoreDevice returns `info.outcome == "success"`.

## Helper script

For repeated USB/LAN installs, invoke `scripts/install_itemdesk_device.sh` from this
skill directory while the shell is in the ItemDesk repository. It reuses the signed app bundle when present, builds when absent,
discovers the requested device, performs the bounded retry above, and writes
logs/results to `/tmp/itemdesk-device-install/`. Set these optional variables:

This helper uses CoreDevice only; it does not implement or select the remote
OTA route. Follow the remote reference for that mode. Before reusing any bundle,
verify its build context matches the requested source; mere existence is not
proof of freshness. Use `ITEMDESK_FORCE_BUILD=1` when freshness is unknown.

- `ITEMDESK_DEVICE_UDID` — explicit physical-device UDID.
- `ITEMDESK_DEVICE_NAME` — device name to select from `devicectl` output. If
  omitted, the helper selects the only available physical device and stops if
  the target is ambiguous.
- `ITEMDESK_PROJECT_ROOT` — ItemDesk repository root; defaults to the current
  directory.
- `ITEMDESK_APP_PATH` — existing signed `.app` to install.
- `ITEMDESK_BUILD_DIR` — derived-data directory; defaults to
  `/tmp/itemdesk-device-install/build`.
- `ITEMDESK_INSTALL_DIR` — log/result directory; defaults to
  `/tmp/itemdesk-device-install`.
- `ITEMDESK_XCODE_DEVICE_DESTINATION=1` — build with
  `platform=iOS,id=<UDID>` instead of the generic iOS destination; use for
  paired/LAN installs.
- `ITEMDESK_DEVICE_DISCOVERY_ATTEMPTS` — bounded post-build discovery attempts;
  defaults to `5`.
- `ITEMDESK_DEVICE_DISCOVERY_DELAY` — seconds between discovery attempts;
  defaults to `4`.

Do not pass reset, uninstall, or test-only launch arguments through the helper.
