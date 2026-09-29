import AppKit
import CoreGraphics

// A per-user launchd helper. No network access, elevated privileges or UI automation.
struct Settings: Codable {
    var delay: Double = 4
    var reminder: Bool = true
}
struct ReminderState: Codable {
    var lastAcknowledgedMonth: String
}
func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d", c.year!, c.month!)
}
func reminderDue(_ date: Date, lastMonth: String) -> Bool {
    monthKey(date) > lastMonth
}
let fm = FileManager.default
let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SpacesWakeFix")
let configURL = base.appendingPathComponent("settings.json")
let stateURL = base.appendingPathComponent("reminder-state.json")
func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

if CommandLine.arguments.contains("--self-test") {
    let january = Date(timeIntervalSince1970: 1768478400) // mid-January 2026
    assert(!reminderDue(january, lastMonth: "2026-01"))
    assert(reminderDue(january, lastMonth: "2025-12"))
    assert(!reminderDue(january, lastMonth: "2026-02")) // clock moved backwards
    assert(monthKey(january) == "2026-01")
    print("Reminder calendar tests passed")
    exit(0)
}
if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--configure" {
    guard let delay = Double(CommandLine.arguments[2]), delay.isFinite,
          (1...60).contains(delay), ["true", "false"].contains(CommandLine.arguments[3]) else {
        fputs("Invalid settings\n", stderr); exit(1)
    }
    try writeJSON(Settings(delay: delay, reminder: CommandLine.arguments[3] == "true"), to: configURL)
    // First reminder is next month; reinstalling preserves acknowledgement history.
    if !fm.fileExists(atPath: stateURL.path) {
        try writeJSON(ReminderState(lastAcknowledgedMonth: monthKey(Date())), to: stateURL)
    }
    exit(0)
}

let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: configURL))
guard settings.delay.isFinite, (1...60).contains(settings.delay) else { exit(1) }
var state = (try? JSONDecoder().decode(ReminderState.self, from: Data(contentsOf: stateURL)))
    ?? ReminderState(lastAcknowledgedMonth: "")
var pendingWake: DispatchWorkItem?
var reminderProcess: Process?
var lastReminderAttempt = Date.distantPast
var screenAsleep = false
var sessionActive = true

func log(_ message: String) { NSLog("[SpacesWakeFix] %@", message) }
// Called only by main-queue reminder checks. Newer SDKs require an explicit
// Sendable annotation; enforce the queue requirement before reading shared state.
@Sendable func unlockedConsoleSession() -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard sessionActive, !screenAsleep,
          let session = CGSessionCopyCurrentDictionary() as? [String: Any],
          session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
    // This lock-state key is undocumented. It is a best-effort reminder guard only;
    // the Dock fix uses the documented NSWorkspace wake event independently.
    return session["CGSSessionScreenIsLocked"] as? Bool != true
}
func checkReminder() {
    guard settings.reminder, reminderProcess == nil, unlockedConsoleSession(),
          reminderDue(Date(), lastMonth: state.lastAcknowledgedMonth),
          Date().timeIntervalSince(lastReminderAttempt) > 3600 else { return }
    lastReminderAttempt = Date()
    let presentedMonth = monthKey(Date())
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", #"""
    display dialog "Spaces Wake Fix is still installed. It restarts Dock after wake as a workaround for the reported macOS 27 Desktop shortcut issue. Check whether an OS update has fixed it, then remove the workaround.\n\nTo uninstall, run this in Terminal:\n\"$HOME/Library/Application Support/SpacesWakeFix/uninstall.sh\"" with title "Spaces Wake Fix — monthly reminder" buttons {"Remind me later", "OK"} default button "OK" cancel button "Remind me later" with icon note
    """#
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { finished in
        DispatchQueue.main.async {
            reminderProcess = nil
            if finished.terminationStatus == 0 {
                let acknowledged = ReminderState(lastAcknowledgedMonth: presentedMonth)
                do {
                    try writeJSON(acknowledged, to: stateURL)
                    state = acknowledged
                } catch { log("Could not save reminder acknowledgement: \(error)") }
            }
        }
    }
    do { try process.run(); reminderProcess = process }
    catch { log("Could not show reminder: \(error)") }
}
func scheduleDockRestart() {
    pendingWake?.cancel()
    let work = DispatchWorkItem {
        pendingWake = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        // Limit explicitly to this user; default SIGTERM lets launchd relaunch Dock.
        process.arguments = ["-u", NSUserName(), "Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            log("Dock restart command exited \(finished.terminationStatus)")
        }
        do { try process.run() } catch { log("Could not restart Dock: \(error)") }
        checkReminder()
    }
    pendingWake = work
    DispatchQueue.main.asyncAfter(deadline: .now() + settings.delay, execute: work)
    log("Wake received; scheduled Dock restart")
}
let center = NSWorkspace.shared.notificationCenter
var observers: [NSObjectProtocol] = []
func observe(_ name: Notification.Name, _ action: @escaping () -> Void) {
    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in action() })
}
observe(NSWorkspace.didWakeNotification) { scheduleDockRestart() }
observe(NSWorkspace.willSleepNotification) { pendingWake?.cancel(); pendingWake = nil }
observe(NSWorkspace.screensDidSleepNotification) { screenAsleep = true }
observe(NSWorkspace.screensDidWakeNotification) { screenAsleep = false; checkReminder() }
observe(NSWorkspace.sessionDidResignActiveNotification) { sessionActive = false }
observe(NSWorkspace.sessionDidBecomeActiveNotification) { sessionActive = true; checkReminder() }
// No private unlock notification dependency: a cheap one-minute reminder check
// also catches midnight, unlock and login while the machine remains awake.
let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in checkReminder() }
timer.tolerance = 10
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { checkReminder() }
signal(SIGTERM, SIG_IGN)
let shutdown = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
shutdown.setEventHandler {
    pendingWake?.cancel()
    reminderProcess?.terminate()
    exit(0)
}
shutdown.resume()
log("Started; delay=\(settings.delay)s, reminder=\(settings.reminder)")
RunLoop.main.run()
