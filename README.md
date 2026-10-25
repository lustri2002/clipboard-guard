# Clipboard Guard

A small macOS menu bar app that keeps Universal Clipboard sharing enabled.

Clipboard Guard watches `ClipboardSharingEnabled` in `com.apple.coreservices.useractivityd`. When the setting is disabled, missing, or stored with the wrong type, it restores boolean `true`, reloads `useractivityd`, and sends a local notification. The notification suggests restarting your iPhone if copying and pasting still does not work.

**This guards a Mac preference. It does not guarantee that Universal Clipboard works, and it cannot detect or repair an iPhone-side failure.**

## How it works

- Listens for preference-file changes and checks the actual value through CFPreferences approximately every two seconds.
- Refreshes the preferences cache before reading. The periodic check covers buffered writes, atomic file replacement, and missed events.
- Repairs the standard preference and an existing host-specific override when necessary, without changing unrelated keys.
- Reloads `useractivityd` after a repair, with at most one reload per minute. It does not restart services on a recurring schedule or clear your clipboard.
- Sends at most one repair notification every 15 minutes. The notification cooldown survives app restarts.
- Starts at login as a user LaunchAgent. `KeepAlive` relaunches the process if it exits. Codex and Terminal do not need to stay open.
- Shows status, a manual check, a test notification, and a log shortcut in the menu bar.

The app does not read or store clipboard contents, open a network listener, or use an external service.

## Requirements

- macOS 13 or later. Local smoke testing was performed on macOS 27.0.1; other versions have not been tested.
- Apple Command Line Tools to build from source. The installer also uses the Python 3 provided by those tools.
- Notification permission for Clipboard Guard if you want alerts.

The app builds for the current Mac's architecture. The local build is ad hoc signed, not notarized.

## Build and install

Clone this repository, then run these commands from its directory:

```sh
./build.sh
./install.command
```

Allow notifications when macOS asks. A clipboard icon appears in the menu bar. Use **Send Test Notification** to check alerts.

Installation is per user and does not require `sudo`. Once installed, the app runs from Application Support and does not depend on the checkout. Run the build and install commands again to update it.

Installed paths:

| Item | Location |
| --- | --- |
| App and instructions | `~/Library/Application Support/Clipboard Guard/` |
| LaunchAgent | `~/Library/LaunchAgents/it.alessiolustri.clipboard-guard.plist` |
| Status | `~/Library/Application Support/Clipboard Guard/status.json` |
| Log | `~/Library/Logs/ClipboardGuard/guard.log` |

Status is written at least once a minute and after a repair. The log rotates at 512 KiB and keeps one previous file.

## Verify

```sh
launchctl print "gui/$(id -u)/it.alessiolustri.clipboard-guard"
defaults read com.apple.coreservices.useractivityd ClipboardSharingEnabled
defaults read-type com.apple.coreservices.useractivityd ClipboardSharingEnabled
cat "$HOME/Library/Application Support/Clipboard Guard/status.json"
```

The preference should be `1`, its type should be boolean, and status should show `healthy: true`. This reports the preference's state, not a successful transfer to another device.

## Uninstall

```sh
./uninstall.command
```

The uninstaller stops the LaunchAgent and moves the installed app directory and LaunchAgent file to Trash. Logs are kept, and clipboard sharing remains enabled. A copy of the uninstaller is also installed in the app's Application Support directory.

## Limitations

- The process runs while the Mac is awake and the user session is active. It resumes checking after wake and starts again at login. It cannot run while the Mac is asleep or powered off.
- If macOS or the user disables this background item, it cannot start automatically.
- Focus and macOS notification settings can silence banners. Preference repair and logging continue without notification permission.
- When the preference is already `true`, an iPhone-side failure does not trigger a repair notification. Restarting the iPhone may still be necessary.
- A managed preference is reported as a repair failure rather than bypassed.
- This maintains an undocumented Apple preference. Future macOS changes may require an update.

## Source and tests

`Sources/main.swift` contains the app, preference handling, and isolated self-tests. `build.sh` creates the app bundle and verifies its ad hoc signature.

```sh
"./Clipboard Guard.app/Contents/MacOS/ClipboardGuard" --self-test
```

The self-tests use the real CFPreferences APIs in a unique temporary domain. They cover missing and false values, external-write cache refresh, type normalization, host overrides, and preservation of unrelated settings. Test keys are cleaned up. The real Universal Clipboard preference is not changed and no system service is restarted by these tests.

The diagnostic mode below reads only this app's notification permissions:

```sh
"./Clipboard Guard.app/Contents/MacOS/ClipboardGuard" --notification-status
```

See [VERIFICATION.md](VERIFICATION.md) for the local smoke-test results and their limits.

## Apple references

- [Universal Clipboard setup and troubleshooting](https://support.apple.com/102430)
- [Creating launchd jobs and KeepAlive](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [CFPreferences synchronization](https://developer.apple.com/documentation/corefoundation/cfpreferencesappsynchronize(_:))
- [Requesting notification authorization](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:))
