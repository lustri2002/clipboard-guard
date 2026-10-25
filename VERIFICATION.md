# Local verification

Date: October 25, 2026. Platform: Apple Silicon, macOS 27.0.1.

## Results

- Swift compilation, shell-script syntax checks, app plist validation, and ad hoc signature verification passed.
- Eight assertions using the real CFPreferences APIs passed in an isolated test domain. They cover missing values, an external false write and cache refresh, repair, preservation of an unrelated key, string-to-boolean normalization, and host-specific overrides.
- A controlled live test temporarily set the actual `ClipboardSharingEnabled` preference to false. The running app restored boolean true in approximately 0.37 seconds. One repair and a successful `useractivityd` reload were recorded.
- The repair notification request was accepted by the notification API. Notification permission, enabled alerts, and banner style were verified. Visual banner delivery was not independently confirmed.
- The app process was terminated in a controlled test. Launchd automatically relaunched it with a new PID, and the preference remained true.
- The installed LaunchAgent uses `RunAtLoad` and `KeepAlive`. The running app reported `healthy: true` and authorized notifications.

## Scope

A full Mac reboot or logout was not performed. Login startup is configured through the LaunchAgent; process recovery was tested directly.

These checks verify preference monitoring and repair. They do not verify an end-to-end transfer to an iPhone or establish that every possible Universal Clipboard failure is fixed.

The self-tests do not change the production preference. The live repair test was performed separately with a cleanup step that restored true if automatic recovery failed.
