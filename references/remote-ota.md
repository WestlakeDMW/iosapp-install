# Remote ItemDesk installation over iOS OTA

Use for remote/OTA requests and cellular deployment tests. The bridge is
`zjz-connect/ios-ota`: https://github.com/zjz-connect/ios-ota.
It installs an Xcode-built, signed device `.app`; it does not provide a native
remote Xcode Run Destination. Do not use the CoreDevice helper for this route.

## Resolve the existing connection

The conventional binary is `$HOME/.local/bin/lyo-nodus-ios-ota`; the conventional
profile is `$HOME/Library/Application Support/Lyo Nodus iOS OTA/iphone.json`.
Prefer explicit paths supplied by the user or a verified existing profile.
Confirm that its device identity and Tailnet address match the intended phone.
Do not hardcode a prior phone address, UDID, repository path, or old build.
Preserve the profile, adjacent socket, and any location configuration in place.

```sh
ios_ota="$HOME/.local/bin/lyo-nodus-ios-ota"
profile="$HOME/Library/Application Support/Lyo Nodus iOS OTA/iphone.json"
"$ios_ota" status --profile "$profile"
```

Require a successful status response with `state: active` before installation.
CoreDevice may report the phone unavailable while this route works.
`doctor` checks prerequisites; Tailscale Connected/ping and `doctor` success
are not substitutes for active Apple pairing and a live tunnel.

If the service is absent or inactive, diagnose the existing setup first.
Do not restart a healthy bridge, recreate pairing, or rerun configure for a
normal install. Start the existing LaunchAgent only when needed and authorized
by the setup task. Both devices need Tailscale online; keep the Mac awake.
Initial acquisition/reconnection needs iPhone Wi-Fi. An active session can
survive switching to cellular; pure-cellular cold start is not supported by
the verified 1.3.1 setup. A DERP relay is usable: failure to establish a direct
Tailscale path does not mean the relay or OTA tunnel failed.

## Build and install

Inspect repository instructions and working tree. Reuse a signed device bundle
only if its source/build context is known to match the request. Otherwise build
the current checkout without changing source, branch, or signing settings:

```sh
install_dir=/tmp/itemdesk-device-install
mkdir -p "$install_dir"
xcodebuild build -project ItemDesk.xcodeproj -scheme ItemDesk \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$install_dir/build" -allowProvisioningUpdates \
  > "$install_dir/build.log" 2>&1
```

After a successful build, verify the bundle before performing installation:

```sh
app_path="$install_dir/build/Build/Products/Debug-iphoneos/ItemDesk.app"
codesign --verify --deep --strict "$app_path"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_path/Info.plist"
```

Require `com.itemdesk.app`, a device build, and valid signing. Then install:

```sh
"$ios_ota" install --profile "$profile" "$app_path" \
  > "$install_dir/ota-install.jsonl" \
  2> "$install_dir/ota-install-error.log"
```

Install over the existing app. Never uninstall or clear its data for an
installation test. Keep the iPhone unlocked for installation. Never substitute
a USB/LAN install to claim that a remote test passed.

## Acceptance and bounded recovery

Require command exit zero and a JSONL terminal event containing all of:
`ok: true`, `final: true`, `event: installed`. The verified implementation waits
for InstallationProxy to read the bundle back from the phone. `accepted`,
progress percentages, `InstallComplete`, and `DataComplete` alone are not the
terminal acceptance signal. Record the bundle ID, final event, and log paths.
Read status again; report its actual state separately from installation.

For a cellular test, have the user confirm Wi-Fi is off and Tailscale remains
on, then verify active status before/after the install. Do not infer cellular
use from a relay connection alone. Stable generation is continuity evidence,
not proof of app startup or UI correctness. Report installation separately
from launch, behavior, and visual verification.

On failure, inspect the final error and status. Do not blindly retry while an
install might still be running. After an explicit transient failure, resolve
connectivity and retry the same signed bundle at most once. If the outer
session was lost, ask for Wi-Fi to reacquire it. Stop on signing errors or
repeated failure and provide the precise blocker; preserve app data and trust.

## Only when first-time pairing is actually needed

Read the current repository README before setup. Reuse trusted private records
when available. The verified setup uses isolated `pymobiledevice3 11.12.4`,
`PairableHostInfo(name="iOS OTA", identifier=<fresh UUID>)`, and
`serve_pairable_host`; the user selects the advertised entry on the iPhone
and enters a short-lived code. Keep the original Xcode/Mac pairing intact.
Store private records in their owner-only location, never in Git or reports;
do not persist the code. Do not invent missing record fields.

Use the actual phone screen to guide the user: in the observed system the
Developer Mode page shows paired devices and an Other Devices discovery list.
Menu wording can vary. Poll the live pairing process after a click before
restarting it; promptly display its code and wait for completion. Verify the
returned phone identity before configuring the profile. After pairing exits,
require the background service to remain active, not just a pairing receipt.

If discovery or connection fails, distinguish phone discovery, incoming TCP,
pairing handshake, and tunnel activation. A temporary connection page proves
TCP reachability only. In one observed setup, upstream discovery plus a listener
accepting both IPv4 and IPv6 succeeded; the incoming connection used a link-local
address. This is a troubleshooting option, not proof of a universal root cause.
Do not routinely restrict advertisement to Wi-Fi alone, replace the upstream
advertiser, or reset device trust. Bound retries and request the current screen
and iOS version when evidence is missing.
