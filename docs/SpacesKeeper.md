# SpacesKeeper — assignment-repair milestone

The restoration engine and automatic reconnect repair have passed the first live test. The native SwiftUI app is now implemented around the same helper; see [NativeApp.md](NativeApp.md) for preview installation, migration and remaining release validation. This document describes the reusable engine and legacy-agent commands.

## Inspection and architecture

The installed service is `org.spaceswakefix.agent`, with its executable and four-second Dock delay in `~/Library/Application Support/SpacesWakeFix`. The agent uses `NSWorkspace` wake/session/screen notifications, Core Graphics reconfiguration callbacks and a quiet-period gate that waits for unlock. Repeated events are coalesced. Its monthly reminder and unified Console logging remain in place.

The new `Sources/Assignments.swift` adds configuration capture, validation, targeted preference writes, verification, independent repair settings and a command-line interface. The existing helper is still the **only background process**. A per-user instance lock prevents a second new helper from registering competing observers. CLI commands exit before registering observers. A separate repair lock serializes capture and restoration across CLI and agent operations.

The single event queue coordinates both fixes. If both are eligible, it waits the longer of their delays, restores assignments, optionally restarts Dock, then verifies the saved bindings again. Dock-only operation keeps the installed delay (four seconds on the development machine; not silently changed to five). Assignment repair defaults to five seconds and also waits until observed Spaces/preferences snapshots stop changing. Settings are reread on events and before pending work; assignment restoration checks its enable switch again before each write. Each event batch gets one attempt, with no retry/write loop.

Assignment failure does not disable the Dock workaround. No saved backup means no automatic assignment writes. Turning off either feature does not turn off the other. Starting the helper is treated as login/startup only for the assignment setting; startup alone never schedules a Dock restart.

## Commands

From the repository after `./install.sh`:

```sh
./spaceskeeper status
./spaceskeeper save
./spaceskeeper restore
./spaceskeeper auto on
./spaceskeeper auto off
./spaceskeeper dock off
./spaceskeeper dock on
./spaceskeeper delay 5
./spaceskeeper display on
./spaceskeeper wake on
./spaceskeeper login on
./spaceskeeper logs
```

Automatic restoration is **off on a new installation** until explicitly enabled. Display, wake and login/startup triggers are independently configurable. `save` is always explicit; no automatic event overwrites the backup. A subsequent save retains one previous copy. Re-running the installer preserves these options and the backup. The existing installer flags still set the independent Dock delay and monthly reminder.

The command is also installed at:

```sh
"$HOME/Library/Application Support/SpacesWakeFix/spaceskeeper" status
```

`status`/`diagnostics` returns JSON with application IDs/names, saved/current bindings, numbered Desktops, UUIDs, connected-display identities and mirroring, OS version, backup timestamp, latest wake/display/start event, latest restoration and latest error/Dock command. This output can be copied for diagnosis; review it before sharing, since installed-app names and display identifiers are included. It does not contain the raw Spaces window lists or collect telemetry.

## Conservative destination matching

The application-owned backup stores a format version, timestamp, bundle IDs, names, original binding values, intended display and Desktop number, ordered Space UUIDs, and the connected-display/mirroring configuration. An empty string is preserved as a real destination if it identifies exactly one ordinary Desktop. Missing dictionary keys are different from empty values.

The current implementation **requires the same display identities, main-display association, mirroring relationships and ordered ordinary Desktop UUIDs**. Changing resolution alone is allowed once stable. Reordered/recreated/deleted Desktops or a regenerated virtual-display identity produce an actionable refusal. The engine never assumes that the same UUID at another Desktop number is still the intended destination, nor guesses replacement UUIDs from an index. Multiple displays are represented separately; ambiguous bindings, including an empty UUID found on multiple displays, cannot be backed up silently. Unsupported special bindings (such as an unrecognised All Desktops token) also require manual review.

macOS does not publish a supported API for these application-to-Space bindings. This milestone reads the observed `SpacesDisplayConfiguration/Management Data/Monitors` schema via `defaults export`. Parsing fails closed when the structure is missing or unsupported. `Main` is resolved against the currently identified main display; topology mismatches block writes. Saved Desktop numbering follows ordinary `type == 0` entries in that monitor's observed order, excluding full-screen app Spaces. Confirm those labels against Mission Control before relying on a new backup.

## Preference access and concurrency

Reads use a fresh `defaults` process to consult the preferences service rather than editing its backing plist. Every update uses separate process arguments equivalent to:

```sh
defaults write com.apple.spaces app-bindings -dict-add APPLICATION_ID SAVED_VALUE
```

Routine repair never replaces `app-bindings` or the whole preference domain. Before each write it rereads topology and the target binding; changed target values stop the operation. After each write it verifies the target and preservation of previously observed unrelated bindings, then verifies the full saved set at the end. A late failure may leave earlier verified repairs applied, which is reported as failure rather than falsely reporting complete success. No stale whole-dictionary rollback is attempted.

This is optimistic concurrency protection, **not an atomic transaction with Dock**: `defaults` exposes no per-entry compare-and-swap API. A concurrent edit inside the read/write interval cannot be excluded completely. Detected conflicts stop repair for manual review. Avoid changing Dock assignments while a repair is underway.

Assignment restoration alone never restarts Dock or claims to move existing windows. macOS may apply the restored assignment on the next application launch; the optional keyboard workaround is a separate operation.

## Files and removal

New application-owned state (all local, user-only directory):

- `~/Library/Application Support/SpacesKeeper/config.json` — explicit backup.
- `config.previous.json` — one previous explicitly saved backup, when applicable.
- `settings.json` — independent repair options.
- `diagnostics.json` — bounded set of latest event/results/error entries.
- `repair.lock` — advisory operation lock.

The existing helper directory also gains the CLI wrapper, `agent.lock`, a previous executable and `rollback-helper.sh`. The same LaunchAgent label is retained. No new agent, daemon, permission prompt or login item is installed by this milestone.

The updated uninstaller removes both support directories, including saved assignment backups, and the one LaunchAgent. To keep a backup, copy the SpacesKeeper directory elsewhere first. It does not remove or reset your actual macOS application bindings. OS-managed logs/caches and the source repository remain.

## Agent rollback and native-app migration

The installer retains the previous executable before updating an existing installation. To return to it:

```sh
./spaceskeeper rollback
```

Rollback stops the current label, restores the previous binary and starts that same label again. It leaves the saved assignments and actual macOS preferences intact. If startup fails, that same command is available directly as `~/Library/Application Support/SpacesWakeFix/rollback-helper.sh`.

The native app implements this handoff using the tested helper as its child process and `SMAppService.mainApp` for login. Preview leaves the old agent active. Activation checks login approval, parks the old plist, starts and verifies the replacement, then records ownership. See the native guide for rollback, failure handling and lifecycle testing. Legacy installer/rollback commands refuse to create a competing agent while native ownership is recorded.

## Validation

`./tests/check.sh` covers the existing wake/display gate plus capture, missing/incorrect/empty bindings, unrelated-entry preservation, idempotence, failed verification, concurrent edits, operation locking, topology mismatch, deleted/reordered Desktops, feature independence and backup persistence. It also uses a uniquely named disposable `org.spaceskeeper.test.*` preferences domain to exercise real `defaults -dict-add` writes and cleanup. **It never deletes Chrome's real binding.**

The live first test saves only the user's approved Mail and Chrome configuration. A no-op restore verifies both live entries without removing them. The physical Thunderbolt reconnect, application relaunch behavior and reboot cannot be proven by fixtures; test those next:

1. Confirm `status` shows the intended Desktop numbers and `Configuration matches backup`.
2. Enable `auto on`; disconnect and reconnect the Thunderbolt display.
3. Wait for the desktop to unlock and settle. Look for `assignments restored` in the existing Console log.
4. Run `status`: both saved entries should be present on the intended Desktops, or there should be a clear topology-refusal error.
5. Test Chrome on a subsequent launch when convenient; an existing window is not expected to move.
6. Repeat with only one fix enabled, and after sleep/reboot. Reordering or deleting a Desktop must refuse stale restoration.

Native UI implementation followed the successful live reconnect evidence below. The generated development app/archive is not a Developer ID signed/notarized public release.

### Development-machine checkpoint — 9 October 2026

The existing service was updated in place with its previous executable retained. The user-approved live backup contains Mail on Desktop 4 and Chrome on Desktop 2. A manual verification and the real automatic login/startup path both returned `0 assignments restored; 2 verified`, with no Dock restart on startup. Automatic assignment restoration is enabled for display, wake and startup; the original Dock workaround remains enabled at four seconds. A subsequent Thunderbolt reconnect test produced two wake-triggered repairs at 13:05:09 and 13:05:55 Europe/London. Each restored one binding, verified both saved bindings and verified them again after a successful Dock restart. Final assignments matched the backup. The log does not identify which application was repaired, and display-only reconnect/native lifecycle coverage remains outstanding.
