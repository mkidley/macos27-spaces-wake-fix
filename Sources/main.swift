import AppKit
import CoreGraphics
import os

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
// Wake or display reconfiguration arms one restart; locked time never counts.
struct RestartGate {
    private(set) var pending = false
    private(set) var readySince: TimeInterval?
    mutating func arm() { pending = true; readySince = nil }
    mutating func resetDelay() { readySince = nil }
    mutating func cancel() { pending = false; readySince = nil }
    mutating func poll(ready: Bool, now: TimeInterval, delay: Double) -> Bool {
        guard pending else { return false }
        guard ready else { readySince = nil; return false }
        guard let started = readySince else { readySince = now; return false }
        guard now >= started else { readySince = now; return false }
        guard now - started >= delay else { return false }
        cancel()
        return true
    }
}
// Use Core Graphics configuration flags rather than broad screen-parameter
// notifications, which can include changes to Dock's usable desktop area.
func relevantDisplayChange(_ flags: CGDisplayChangeSummaryFlags) -> Bool {
    guard !flags.contains(.beginConfigurationFlag) else { return false }
    let relevant: CGDisplayChangeSummaryFlags = [
        .setModeFlag, .setMainFlag, .addFlag, .removeFlag,
        .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag
    ]
    return !flags.intersection(relevant).isEmpty
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

do {
    if try keeperCLI(Array(CommandLine.arguments.dropFirst())) { exit(0) }
} catch {
    fputs("SpacesKeeper: \(error.localizedDescription)\n", stderr)
    exit(1)
}

if CommandLine.arguments.contains("--self-test") {
    let january = Date(timeIntervalSince1970: 1768478400) // mid-January 2026
    assert(!reminderDue(january, lastMonth: "2026-01"))
    assert(reminderDue(january, lastMonth: "2025-12"))
    assert(!reminderDue(january, lastMonth: "2026-02")) // clock moved backwards
    assert(monthKey(january) == "2026-01")
    var gate = RestartGate()
    func poll(_ ready: Bool, _ seconds: Double) -> Bool {
        gate.poll(ready: ready, now: seconds, delay: 4)
    }
    assert(!poll(true, 0)) // unlock alone cannot trigger a restart
    gate.arm()
    assert(!poll(false, 0))
    assert(!poll(false, 3600)) // long locked or dark-wake interval
    assert(!poll(true, 3601)) // unlock starts the delay
    assert(!poll(true, 3604))
    assert(poll(true, 3605))
    assert(!poll(true, 3610)) // exactly once
    gate.arm()
    assert(!poll(true, 4000))
    assert(!poll(false, 4002)) // lock again during the delay
    assert(!poll(true, 4010))
    assert(!poll(true, 4013))
    assert(poll(true, 4014))
    gate.arm()
    assert(!poll(true, 5000))
    gate.cancel() // sleep again before the delay expires
    assert(!poll(true, 5010))
    gate.arm()
    assert(!poll(true, 6000))
    gate.arm() // duplicate wake restarts the settling delay
    assert(!poll(true, 6002))
    assert(!poll(true, 6004))
    assert(poll(true, 6006))
    // A burst of mirror/virtual-display events shares one settling delay.
    gate.arm()
    assert(!poll(true, 7000))
    gate.arm()
    assert(!poll(true, 7002))
    gate.arm()
    assert(!poll(true, 7005))
    assert(!poll(true, 7008))
    assert(poll(true, 7009))
    assert(!poll(true, 7015))
    // A new configuration beginning during the delay must defer the restart.
    gate.arm()
    assert(!poll(true, 8000))
    gate.resetDelay()
    assert(!poll(false, 8005))
    assert(!poll(true, 8010))
    assert(!poll(true, 8013))
    assert(poll(true, 8014))
    for flags: CGDisplayChangeSummaryFlags in [
        .setModeFlag, .setMainFlag, .addFlag, .removeFlag,
        .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag
    ] { assert(relevantDisplayChange(flags)) }
    assert(!relevantDisplayChange([]))
    assert(!relevantDisplayChange(.beginConfigurationFlag))
    assert(!relevantDisplayChange([.beginConfigurationFlag, .setModeFlag]))
    assert(!relevantDisplayChange(.desktopShapeChangedFlag))
    assert(!relevantDisplayChange(.movedFlag))
    assert(relevantDisplayChange([.desktopShapeChangedFlag, .setModeFlag]))
    print("Reminder, wake/unlock, display-change filtering and debounce tests passed")
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

var settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: configURL))
guard settings.delay.isFinite, (1...60).contains(settings.delay) else { exit(1) }
var state = (try? JSONDecoder().decode(ReminderState.self, from: Data(contentsOf: stateURL)))
    ?? ReminderState(lastAcknowledgedMonth: "")
var restartGate = RestartGate()
var restartTimer: Timer?
var reminderProcess: Process?
var lastReminderAttempt = Date.distantPast
var screenAsleep = false
var sessionActive = true
var displayReconfiguring = false
var dockRestartInFlight = false
var pendingTriggers = Set<String>()
var lastAssignmentSnapshot: KeeperSnapshot?
// One daemon instance, even when a user accidentally launches the helper twice.
let daemonLock: KeeperLock
do { daemonLock = try KeeperLock(base.appendingPathComponent("agent.lock")) }
catch { fputs("Another helper instance is running.\n", stderr); exit(0) }
func selectedRepairs(_ options: KeeperOptions) -> (assignments: Bool, dock: Bool) {
    keeperSelection(options, triggers: pendingTriggers)
}

let logger = Logger(subsystem: "org.spaceswakefix.agent", category: "lifecycle")
func log(_ message: String) { logger.notice("\(message, privacy: .public)") }
// Called only by main-queue wake and reminder checks. Newer SDKs require an explicit
// Sendable annotation; enforce the queue requirement before reading shared state.
@Sendable func unlockedConsoleSession() -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard sessionActive, !screenAsleep,
          let session = CGSessionCopyCurrentDictionary() as? [String: Any],
          session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
    // This lock-state key is undocumented. A missing key is treated as unlocked;
    // screen and console-session checks still gate both wake fixes and reminders.
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
    display dialog "Spaces Wake Fix is still installed. It restarts Dock after wake or display-mode changes as a workaround for the reported macOS 27 Desktop shortcut issue. Check whether an OS update has fixed it, then remove the workaround.\n\nTo uninstall, run this in Terminal:\n\"$HOME/Library/Application Support/SpacesWakeFix/uninstall.sh\"" with title "Spaces Wake Fix — monthly reminder" buttons {"Remind me later", "OK"} default button "OK" cancel button "Remind me later" with icon note
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
func checkPendingRestart() {
    guard restartGate.pending, !dockRestartInFlight else { return }
    let wasSettling = restartGate.readySince != nil
    guard let options = try? keeperOptions() else {
        log("Invalid SpacesKeeper settings; repair cancelled. Existing settings file preserved.")
        cancelPendingRestart(); return
    }
    if let updated = try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: configURL)),
       updated.delay.isFinite, (1...60).contains(updated.delay) { settings = updated }
    let manualDock = pendingTriggers.contains("manual")
    let selected = selectedRepairs(options)
    if !selected.assignments && !selected.dock { cancelPendingRestart(); return }
    let ready = !displayReconfiguring && unlockedConsoleSession()
    if selected.assignments && ready {
        // Preferences/topology must also stop changing before the shared delay.
        if let snapshot = try? SystemKeeperPreferences().read() {
            if lastAssignmentSnapshot != snapshot {
                restartGate.resetDelay()
                lastAssignmentSnapshot = snapshot
            }
        }
    }
    let effectiveDelay = max(selected.assignments ? options.restorationDelay : 0,
                             selected.dock ? settings.delay : 0)
    let restart = restartGate.poll(ready: ready, now: ProcessInfo.processInfo.systemUptime,
                                delay: effectiveDelay)
    if !ready && wasSettling { log("Desktop no longer ready; settling delay reset") }
    if ready && !wasSettling { log("Desktop ready; starting \(effectiveDelay)s settling delay") }
    guard restart else { return }
    restartTimer?.invalidate()
    restartTimer = nil
    pendingTriggers.removeAll()
    lastAssignmentSnapshot = nil
    if selected.assignments {
        let engine = KeeperEngine()
        if FileManager.default.fileExists(atPath: engine.backupURL.path) {
            do {
                let result = try engine.restore { try keeperOptions().automaticRestoration }
                log(result.message)
                keeperDiagnosticRecord("lastRestoration", result.message)
            } catch {
                log("Assignment restoration refused/failed: \(error.localizedDescription)")
                keeperDiagnosticRecord("lastError", error.localizedDescription)
            }
        } else { log("No saved assignments; automatic restoration skipped") }
    }
    guard selected.dock && (manualDock || (try? keeperOptions().dockWorkaround) == true) else { checkReminder(); return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["-u", NSUserName(), "Dock"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { finished in
        log("Dock restart command exited \(finished.terminationStatus)")
        DispatchQueue.main.async {
            dockRestartInFlight = false
            keeperDiagnosticRecord("lastDockRestart", "Command exited \(finished.terminationStatus)")
            // Verify after Dock reloaded preferences; never enter a retry/write loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard selected.assignments, FileManager.default.fileExists(atPath: KeeperEngine().backupURL.path) else { return }
                do {
                    let engine = KeeperEngine()
                    let saved = try engine.load()
                    let current = try engine.preferences.read()
                    try keeperValidate(saved, current: current)
                    guard saved.assignments.allSatisfy({ current.bindings[$0.bundleID] == $0.target.uuid }) else {
                        throw KeeperFailure("Assignments differ after Dock restart. Manual review required.")
                    }
                    log("Saved assignments verified after Dock restart")
                } catch { log(error.localizedDescription); keeperDiagnosticRecord("lastError", error.localizedDescription) }
            }
        }
    }
    log("Restarting Dock after trigger settled and desktop became ready")
    dockRestartInFlight = true
    do { try process.run() } catch { dockRestartInFlight = false; log("Could not restart Dock: \(error)") }
    checkReminder()
}
func scheduleDockRestart(reason: String = "Wake received", trigger: String = "wake") {
    pendingTriggers.insert(trigger)
    keeperDiagnosticRecord(trigger == "display" ? "lastDisplayEvent" : trigger == "wake" ? "lastWake" : "lastStart", reason)
    guard let options = try? keeperOptions() else {
        log("Invalid SpacesKeeper settings; repair cancelled. Existing settings file preserved.")
        cancelPendingRestart(); return
    }
    let selected = selectedRepairs(options)
    guard selected.assignments || selected.dock else { pendingTriggers.removeAll(); return }
    lastAssignmentSnapshot = nil
    restartTimer?.invalidate()
    restartGate.arm()
    log("\(reason); waiting for an unlocked, active desktop and stable displays")
    // Poll only while a restart is pending. Ordinary unlocks need not emit a
    // workspace session-activation event, so that event alone is insufficient.
    restartTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        checkPendingRestart()
    }
    restartTimer?.tolerance = 0.1
    checkPendingRestart()
}
func cancelPendingRestart() {
    if restartGate.pending { log("Pending restart cancelled") }
    restartGate.cancel()
    pendingTriggers.removeAll()
    lastAssignmentSnapshot = nil
    restartTimer?.invalidate()
    restartTimer = nil
}
// Core Graphics may call on another thread. Serialize all state on the main
// queue, alongside workspace notifications and the readiness timer.
let displayCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    DispatchQueue.main.async {
        if flags.contains(.beginConfigurationFlag) {
            displayReconfiguring = true
            restartGate.resetDelay()
            return
        }
        displayReconfiguring = false
        if relevantDisplayChange(flags) {
            scheduleDockRestart(reason: "Display configuration changed (flags=\(flags.rawValue))", trigger: "display")
        } else {
            checkPendingRestart()
        }
    }
}
let displayRegistration = CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
if displayRegistration == .success {
    log("Display reconfiguration monitoring enabled")
} else {
    log("Display monitoring registration failed: \(displayRegistration.rawValue); wake monitoring remains active")
}
let center = NSWorkspace.shared.notificationCenter
var observers: [NSObjectProtocol] = []
func observe(_ name: Notification.Name, _ action: @escaping () -> Void) {
    observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in action() })
}
observe(NSWorkspace.didWakeNotification) { scheduleDockRestart() }
observe(NSWorkspace.willSleepNotification) { cancelPendingRestart(); displayReconfiguring = false }
observe(NSWorkspace.screensDidSleepNotification) { screenAsleep = true; checkPendingRestart() }
observe(NSWorkspace.screensDidWakeNotification) { screenAsleep = false; checkPendingRestart(); checkReminder() }
observe(NSWorkspace.sessionDidResignActiveNotification) { sessionActive = false; checkPendingRestart() }
observe(NSWorkspace.sessionDidBecomeActiveNotification) { sessionActive = true; checkPendingRestart(); checkReminder() }
// No private unlock notification dependency: a cheap one-minute reminder check
// also catches midnight, unlock and login while the machine remains awake.
let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in checkReminder() }
timer.tolerance = 10
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { checkReminder() }
signal(SIGTERM, SIG_IGN)
let shutdown = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
shutdown.setEventHandler {
    cancelPendingRestart()
    if displayRegistration == .success {
        CGDisplayRemoveReconfigurationCallback(displayCallback, nil)
    }
    reminderProcess?.terminate()
    exit(0)
}
shutdown.resume()
log("Started; delay=\(settings.delay)s, reminder=\(settings.reminder)")
scheduleDockRestart(reason: "Helper started (login/startup check)", trigger: "login")
// UI commands use one event-driven request channel, never a second killall process.
try keeperPrepare(keeperDirectory)
let requestURL = keeperDirectory.appendingPathComponent("manual-dock-request.json")
func consumeManualRequest() {
    guard let data = try? Data(contentsOf: requestURL) else { return }
    do {
        try FileManager.default.removeItem(at: requestURL)
        let requested = try keeperDecode(Date.self, data)
        guard abs(requested.timeIntervalSinceNow) < 60 else { return }
        scheduleDockRestart(reason: "Manual Dock restart requested", trigger: "manual")
    } catch { log("Could not read manual request: \(error)") }
}
let requestDescriptor = open(keeperDirectory.path, O_EVTONLY)
guard requestDescriptor >= 0 else { log("Cannot monitor manual repair requests"); exit(1) }
let requestWatcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: requestDescriptor, eventMask: .write, queue: .main)
requestWatcher.setEventHandler { consumeManualRequest() }
requestWatcher.setCancelHandler { close(requestDescriptor) }
requestWatcher.resume()
consumeManualRequest()
RunLoop.main.run()
