# SpacesKeeper native app — 0.2.0 development build

SpacesKeeper now has a native SwiftUI configuration window, settings and diagnostics, plus a macOS menu-bar menu. The interface uses the tested assignment engine and the existing wake/display helper. No web runtime or third-party libraries are used.

## Live evidence

On 9 October 2026, the user's Thunderbolt reconnect test produced two wake-triggered repair runs at 13:05:09 and 13:05:55 Europe/London. Each restored one assignment and verified both saved entries. The coordinated Dock restart exited successfully and the assignments were verified again afterwards. The final state was Chrome → Desktop 2 and Mail → Desktop 4. The log counts do not identify which app was repaired; display-only reconnection remains a separate test.

This proves the first live restoration milestone for that layout. It does not prove every display topology, every OS build or native-app migration/reboot behavior.

## Build and install

Requires Apple Command Line Tools or Xcode. Use the toolchain selected on your Mac; if Xcode is awaiting its licence but the separately installed Command Line Tools are already usable, a per-command `DEVELOPER_DIR=/Library/Developer/CommandLineTools` can select those without changing system configuration.

```sh
./tests/check.sh
./install-app.sh
```

This builds a local application for the current architecture, installs it at `~/Applications/SpacesKeeper.app`, and opens it. For Apple Silicon plus Intel slices:

```sh
./install-app.sh --universal
```

The tested development machine is Apple Silicon. Both architectures can be packaged, but Intel execution was not tested because Rosetta is unavailable on that machine; the installed toolchain also emitted Intel compatibility-library linker warnings. Do not advertise Intel support as verified until it is run on suitable hardware.

The app targets macOS 13+ APIs, but the Spaces preferences parser and repair behavior have only been exercised against the observed macOS 27 schema. An earlier OS is not a verified target merely because the app compiles for it.

The installer does not overwrite a running app. Updates keep an existing bundle as `SpacesKeeper.previous.app`; move that recovery copy somewhere safe before installing another update. It does not touch the working LaunchAgent during preview installation.

## Preview and takeover

When the old agent is present, the app opens in **preview mode**. The existing agent keeps handling repairs. Configuration, save/restore and diagnostics use short-lived CLI calls that do not register event observers. Automatic-repair switches operate on shared settings; the Dock-delay control is disabled during preview until the native app owns the helper.

After reviewing the configuration, click **Start SpacesKeeper Repairs…**:

1. Register the app with Apple's `SMAppService.mainApp` for login. If System Settings approval is required, the old agent stays active and the app asks you to approve it first.
2. Stop the existing service and move its plist into the SpacesKeeper support directory for rollback.
3. Start the bundled version of the same helper as one child process. A shared instance lock prevents competing observers and Dock restarts.
4. Check that the child is still running, responds to diagnostics and reports a fresh startup. Only then record native ownership.
5. If handoff fails, stop the child and attempt to restore the old agent. Errors remain visible for manual review.

The app is the login item after takeover; it owns the helper and stops it when you quit. Unexpected helper exits are reported and retried at most three times per minute. Neither the UI nor its diagnostics watcher performs an independent automatic repair. Manual Restart Dock requests go through the helper's same serialized event queue.

A failed rollback is never described as a completed migration. Review Settings/Console if both old plist locations exist, login registration fails or the child cannot start. The preserved old helper and plist remain recoverable.

## Interface

- **Spaces Configuration:** saved apps grouped by display and Desktop, resolved app icons/names, backup time, match/missing/different/layout status; explicit Save and Restore actions. Saving requires confirmation and keeps one previous backup.
- **Settings:** independent assignment and Dock workarounds; display/wake/login restoration; settling delays; Launch at Login; menu-bar visibility; rollback and uninstall.
- **Menu bar:** configuration status, last repair, Save, Restore, Restart Dock Now, Settings, Logs and Quit.
- **Diagnostics:** current/saved mappings, display IDs, Space UUIDs, OS version, events and errors, with Copy Diagnostics and Open Console.

Hiding the menu icon switches the app to a normal Dock application, so it remains accessible. Reopening the app from Applications brings back the configuration window. Automatic success is silent. Failure notifications are requested only after native ownership is activated; macOS permission and Focus settings still control delivery. Errors also remain in the window/diagnostics if notifications are declined.

The app never moves or relaunches another application's existing windows.

## Data, privacy and permissions

The engine's schema, strict topology matching and optimistic concurrency limits are documented in [SpacesKeeper.md](SpacesKeeper.md). This is not a supported Apple API for managing Spaces: the preference schema and lock-state key remain implementation details that may change. Ambiguous layouts are refused.

No administrator access, Accessibility, Full Disk Access, screen recording, analytics or external service is required. Native UI state and ownership files live in `~/Library/Application Support/SpacesKeeper` alongside the assignment backup. App/process locks and a one-shot manual-request file also live there. The helper still reads the existing Dock delay/monthly-reminder settings under `~/Library/Application Support/SpacesWakeFix`.

The diagnostics watcher checks only the local results file while idle; preference snapshots are refreshed for events and UI activity. Diagnostics contain application names and display identifiers, so review them before sharing. All notifications and logs are local.

## Rollback and uninstall

To return to the previous agent, use **Settings → Return to Previous LaunchAgent…**. This unregisters the app's login item, stops its child and restores the parked plist. Saved assignments remain intact. The older command-line binary rollback remains available after native ownership has been relinquished.

To uninstall both the app and the old workaround, use **Settings → Uninstall SpacesKeeper…**, or from the repository:

```sh
./uninstall-app.sh
```

The installed bundle also contains the same command:

```sh
"$HOME/Applications/SpacesKeeper.app/Contents/Resources/uninstall-app.sh"
```

Uninstall unregisters the login item, stops the app/helper and old service, then removes the one LaunchAgent, both support directories (including backups) and the installed app. Actual `com.apple.spaces` bindings are left alone. Copy a backup elsewhere first if you want to keep it. Source files, previous app bundles retained for recovery and OS-managed caches/logs are not removed. If shutdown or unregistering fails, inspect the reported error and retry; do not assume deletion succeeded.

Automatic bundle removal is restricted to the supported `~/Applications/SpacesKeeper.app` location. For another installation location, quit the app, unregister its login item through Settings (or that bundle's `--unregister-login` command), run the cleanup script for user state, and remove the custom-location bundle yourself.

## Release packaging

```sh
./package-release.sh
```

Creates `.build/SpacesKeeper-0.2.0-universal.zip`. Builds are ad-hoc signed for local use by default. **They are not Developer ID signed or notarized public releases.** To sign with your own existing identity:

```sh
SPACESKEEPER_SIGN_IDENTITY='Developer ID Application: YOUR IDENTITY' ./package-release.sh
```

Then submit the archive using your own configured `notarytool` credentials, wait for acceptance, staple the app, and recreate the archive. No signing credentials are stored in this repository and the build scripts never submit automatically. Do not bypass Gatekeeper or remove quarantine as an installation instruction.

## Development validation

The helper regression suite and isolated preference-domain integration tests passed. The native configuration, settings and diagnostics views were rendered with synthetic assignments and visually inspected. The universal bundle passed signature verification and its bundled helper check. The installed app was opened in preview mode on Apple Silicon: the existing agent stayed running, no second repair helper started, and the Mail/Chrome backup still matched. An additional live Codex binding was preserved and was not silently added to the saved backup.

## Validation still requiring a person

The regression suite covers preference repair and event policy, and the build checks the bundle/signature and bundled helper. The real reconnect repair above was verified using the agent. Before a public release, exercise native takeover/rollback, login approval and reboot, menu-icon hiding/reopening, notification denial, uninstall, and Intel execution on target hardware. A running preview window does not establish those lifecycle tests.

Reference: [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) and [main app login registration](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp).
