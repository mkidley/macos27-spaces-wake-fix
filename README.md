# Spaces Wake Fix

A small, local workaround for a **reported macOS 27 Mission Control/Spaces issue**: after sleep, Control–1 still switches to Desktop 1, but Control–2 and higher fail. If restarting Dock restores those shortcuts on your Mac, this project automates that workaround.

This is not an Apple fix, and the underlying cause and affected OS builds have not been established here. Remove it when you no longer need it.

## What it does

A per-user LaunchAgent runs a small Swift command-line helper. It listens for the documented `NSWorkspace.didWakeNotification`, waits **4 seconds**, then runs `/usr/bin/killall -u YOUR_USERNAME Dock`. macOS relaunches Dock. Other apps are not deliberately terminated, but Dock, Mission Control and Spaces animations may briefly disappear or reset.

LaunchAgent property lists have no built-in system-wake trigger. The helper gives us native event detection without polling power logs, Homebrew, SleepWatcher, a full app, or a background Swift interpreter. The installer compiles the source once using Apple's Command Line Tools.

Screen-only wake, login and unlock do **not** trigger a Dock restart. Repeated wake events during the delay are coalesced; another sleep cancels a pending restart. The fix does not depend on the reminder or its lock-state detection. There is no Dock restart just from installing or logging in.

## Install

Requirements: macOS, a logged-in desktop session, and Apple Command Line Tools (or Xcode with a selected toolchain). Intended for the reported macOS 27 issue; no claim of testing every macOS 27 build or Mac model. If the compiler is missing, first run `xcode-select --install` and finish Apple's installation.

Download/clone this repository, open Terminal in its folder, then:

```sh
./install.sh
```

Do not use `sudo`. No downloaded binaries or network installation steps are used by the script. The repository may be moved or deleted after installation.

Optional settings:

```sh
./install.sh --delay 5 --no-reminder
```

Delay accepts 1–60 seconds; 3–5 seconds is a reasonable starting point. To update or change settings, rerun the installer from the desired source version. Every run uses the supplied settings, defaulting to 4 seconds and reminders enabled. Existing monthly acknowledgement state is preserved. Compilation happens before an existing agent is stopped; later installation failures leave files available for troubleshooting or uninstall.

## Uninstall

From anywhere, even after deleting the repository:

```sh
"$HOME/Library/Application Support/SpacesWakeFix/uninstall.sh"
```

Or, from the repository:

```sh
./uninstall.sh
```

This stops the agent and its reminder process, removes its LaunchAgent, helper, settings, reminder state and installed uninstaller. It is safe to rerun the repository uninstaller. The downloaded repository and macOS-managed unified log entries remain. No system preferences or keyboard shortcuts need restoring.

## Monthly reminder

Enabled by default. The first reminder is due on the **first day of the month after installation**, using the Mac's local calendar. A small dialog explains the workaround and shows the uninstall command. Click **OK** to acknowledge that month; **Remind me later** retries no sooner than an hour later.

If the Mac is asleep, locked or unused on the first, the reminder catches up at the next available session. Missed months produce one current reminder, not a backlog. A lightweight timer checks eligibility once a minute, with scheduling tolerance, and workspace activity also prompts a check. The timer never restarts Dock. Acknowledgement is saved only after OK, so restarting the helper does not discard an unacknowledged reminder.

Unlock gating is **best effort**: console-session and screen-wake information comes from macOS, but the `CGSSessionScreenIsLocked` dictionary key is undocumented and may change. If unavailable, a dialog could be created behind the lock screen and become visible on unlock. There is no private unlock-notification dependency. The dialog is used instead of a notification banner so notification permissions or Focus do not silently hide the monthly message. It runs in a separate process so it cannot block wake handling. No reminder changes or removes the workaround automatically.

Disable reminders by rerunning `./install.sh --no-reminder`; rerun `./install.sh` to enable them. Disabling does not erase saved acknowledgement history.

## Installed files

All paths are under the installing user's home directory:

| Path | Purpose |
| --- | --- |
| `~/Library/LaunchAgents/org.spaceswakefix.agent.plist` | Starts the helper at login and restarts it if it exits |
| `~/Library/Application Support/SpacesWakeFix/spaces-wake-fix` | Locally compiled helper |
| `~/Library/Application Support/SpacesWakeFix/settings.json` | Delay and reminder setting |
| `~/Library/Application Support/SpacesWakeFix/reminder-state.json` | Last acknowledged month only |
| `~/Library/Application Support/SpacesWakeFix/uninstall.sh` | Self-contained removal command |

`org.spaceswakefix.agent` is a project identifier, not a claim of ownership of a domain. The support directory is exclusively reserved for this project and is removed in full on uninstall. Compiler temporary files are removed on normal script exit. There is no separate log file or scheduled cloud task.

## Troubleshooting

Check whether the agent is loaded:

```sh
launchctl print "gui/$(id -u)/org.spaceswakefix.agent"
```

View recent events (in Terminal, or search `SpacesWakeFix` in Console):

```sh
log show --last 1h --style compact --predicate 'eventMessage CONTAINS "[SpacesWakeFix]"'
```

A wake should produce a scheduled-restart entry and a command exit status. Status 0 means Dock was signalled, not proof that the OS bug was fixed. A nonzero status can mean no matching Dock process was running. Log retention is controlled by macOS.

If shortcuts still fail, confirm multiple desktops and their keyboard shortcuts exist, then check whether manually running `killall Dock` helps. If it does, try reinstalling with `--delay 5`. If it does not, this workaround may not address your issue. Do not expect a display-only wake to trigger the fix; test actual system sleep.

If the agent is missing, rerun the installer from a desktop Terminal session. If you manually disabled its launchd label, re-enable it with `launchctl enable "gui/$(id -u)/org.spaceswakefix.agent"` before reinstalling. A compiler/SDK mismatch requires a matching Apple toolchain; the installer does not change your Xcode selection. Settings are read at helper startup; prefer changing them through the installer.

For reminder testing, temporarily edit `lastAcknowledgedMonth` in the installed `reminder-state.json` to an earlier `YYYY-MM`, then restart the helper with `launchctl kickstart -k "gui/$(id -u)/org.spaceswakefix.agent"`. Within about a minute of an unlocked session, a dialog should appear. OK restores the current month. This tests display and persistence without changing the system clock.

## Security and privacy

No network calls, telemetry, analytics, credentials, Accessibility permission, Full Disk Access or admin access. The helper observes workspace lifecycle events, reads console/lock state for reminder timing, and signals only the current user's Dock. It does not capture keystrokes, screen content or application documents. Reminder text is fixed AppleScript passed directly to `osascript`, without shell evaluation or application-control commands. Settings and month state stay locally in a user-only directory. Logs contain lifecycle/exit/error information.

The helper is compiled for your Mac's architecture. It is not a notarized distribution app. Review the short source and scripts before running them. Normal macOS and developer-tool caches or unified logs are OS-managed and are not purged by uninstall.

## Development and validation

```sh
./tests/check.sh
```

Checks shell syntax, compiles the helper and reminder AppleScript, and exercises reminder month rollover, same-month suppression and backwards-clock behavior. It does not install an agent, display a dialog, sleep the Mac or restart Dock. Run from a normal Terminal session; restricted sandboxes may prevent AppleScript from loading macOS scripting additions.

Before publishing a release, manually verify on your target macOS build:

1. Install, confirm the loaded agent, and verify no immediate Dock restart.
2. Sleep/wake; confirm exactly one restart after the delay and test Desktop 2+ shortcuts.
3. Lock/unlock and display-only wake; confirm no restart. Sleep again before a pending delay finishes; confirm cancellation.
4. Test a due reminder while locked, then unlock and acknowledge it; restart the helper and confirm it stays suppressed. Test deferred acknowledgement and reminders disabled.
5. Reinstall with different settings. Uninstall, confirm the label and installed paths are gone, then sleep/wake to confirm the workaround has stopped.

These checks are necessary because compilation and unit checks cannot prove behavior across real sleep, dark wake, lock-screen and OS-version conditions.

API references: [Apple's system-wake notification](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification), [screen-wake notification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification), and [console-session dictionary](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary()).

## License

MIT — see [LICENSE](LICENSE).
