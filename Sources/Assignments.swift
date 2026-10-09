import AppKit
import CoreGraphics
import Darwin

struct KeeperFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct KeeperOptions: Codable {
    var automaticRestoration = false
    var restoreOnDisplay = true
    var restoreAfterWake = true
    var restoreAtLogin = true
    var restorationDelay: Double = 5
    var dockWorkaround = true
}
func keeperSelection(_ options: KeeperOptions, triggers: Set<String>) -> (assignments: Bool, dock: Bool) {
    let assignments = options.automaticRestoration && (
        (triggers.contains("wake") && options.restoreAfterWake) ||
        (triggers.contains("display") && options.restoreOnDisplay) ||
        (triggers.contains("login") && options.restoreAtLogin))
    return (assignments, triggers.contains("manual") || (options.dockWorkaround && !triggers.subtracting(["login"]).isEmpty))
}
struct KeeperDisplay: Codable, Equatable {
    let id: String
    let mirrorOf: String?
    let main: Bool
    let width: Int
    let height: Int
    // Mode changes can settle without invalidating a saved display identity.
    var identity: String { "\(id)|\(mirrorOf ?? "none")|\(main)" }
}
struct KeeperDesktop: Codable, Equatable {
    let display: String
    let number: Int
    let uuid: String
}
struct KeeperSnapshot: Codable, Equatable {
    let displays: [KeeperDisplay]
    let desktops: [KeeperDesktop]
    let bindings: [String: String]
    func sameDestinations(as other: KeeperSnapshot) -> Bool {
        displays.map(\.identity) == other.displays.map(\.identity) && desktops == other.desktops
    }
}
struct KeeperAssignment: Codable {
    let bundleID: String
    let name: String
    let target: KeeperDesktop
}
struct KeeperBackup: Codable {
    let formatVersion: Int
    let savedAt: Date
    let snapshot: KeeperSnapshot
    let assignments: [KeeperAssignment]
}
struct KeeperReport: Codable {
    let restored: Int
    let verified: Int
    let message: String
}
let keeperDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/SpacesKeeper", isDirectory: true)

func keeperEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}
func keeperDecode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
}
func keeperPrepare(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
}
func keeperWrite<T: Encodable>(_ value: T, _ url: URL) throws {
    try keeperPrepare(url.deletingLastPathComponent())
    try keeperEncode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
final class KeeperLock {
    private let descriptor: Int32
    init(_ url: URL) throws {
        try keeperPrepare(url.deletingLastPathComponent())
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw KeeperFailure("Cannot open operation lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw KeeperFailure("Another SpacesKeeper operation is running. Try again after it finishes.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
func keeperOptions() throws -> KeeperOptions {
    let url = keeperDirectory.appendingPathComponent("settings.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return KeeperOptions() }
    let value = try keeperDecode(KeeperOptions.self, Data(contentsOf: url))
    guard value.restorationDelay.isFinite, (1...60).contains(value.restorationDelay) else {
        throw KeeperFailure("Restoration delay must be from 1 to 60 seconds.")
    }
    return value
}
// Only spawn fixed executables with separate arguments; no shell interpolation.
func keeperCommand(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw KeeperFailure("\(URL(fileURLWithPath: executable).lastPathComponent) exited \(process.terminationStatus). No whole-domain rewrite was attempted.")
    }
    return data
}
func keeperDisplayUUID(_ id: CGDirectDisplayID) throws -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
        throw KeeperFailure("Cannot identify a connected display. Manual intervention required.")
    }
    return CFUUIDCreateString(nil, uuid) as String
}
func keeperDisplays() throws -> [KeeperDisplay] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
        throw KeeperFailure("No stable online display configuration is available.")
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
        throw KeeperFailure("Display enumeration changed. Wait for displays to settle.")
    }
    let result = try ids.prefix(Int(count)).map { id -> KeeperDisplay in
        let mirror = CGDisplayMirrorsDisplay(id)
        return try KeeperDisplay(id: keeperDisplayUUID(id),
            mirrorOf: mirror == kCGNullDirectDisplay ? nil : keeperDisplayUUID(mirror),
            main: id == CGMainDisplayID(), width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id))
    }.sorted { $0.id < $1.id }
    guard Set(result.map(\.id)).count == result.count else {
        throw KeeperFailure("Display identifiers are ambiguous. Restoration is disabled for this configuration.")
    }
    return result
}
func keeperParse(_ root: [String: Any], displays: [KeeperDisplay]) throws -> KeeperSnapshot {
    let bindings: [String: String]
    if let raw = root["app-bindings"] {
        guard let dictionary = raw as? [String: String] else { throw KeeperFailure("Unsupported app-bindings format.") }
        bindings = dictionary
    } else { bindings = [:] }
    guard let configuration = root["SpacesDisplayConfiguration"] as? [String: Any],
          let management = configuration["Management Data"] as? [String: Any],
          let monitors = management["Monitors"] as? [[String: Any]], !monitors.isEmpty else {
        throw KeeperFailure("Desktop layout is unavailable or uses an unsupported preferences schema. No assignments written.")
    }
    var desktops: [KeeperDesktop] = []
    for monitor in monitors {
        guard let rawDisplay = monitor["Display Identifier"] as? String,
              let spaces = monitor["Spaces"] as? [[String: Any]], !spaces.isEmpty else {
            throw KeeperFailure("Incomplete Desktop configuration. Wait for the display to reconnect.")
        }
        let display: String
        if rawDisplay == "Main" {
            guard let main = displays.first(where: \.main) else { throw KeeperFailure("Main display cannot be identified.") }
            display = main.id
        } else {
            guard displays.contains(where: { $0.id == rawDisplay }) else {
                throw KeeperFailure("A saved display group is not currently connected. No assignments written.")
            }
            display = rawDisplay
        }
        var number = 0
        for space in spaces {
            guard let type = space["type"] as? Int else { throw KeeperFailure("Unrecognised Space type.") }
            if type != 0 { continue } // Full-screen application spaces are not numbered Desktops.
            guard let uuid = space["uuid"] as? String else { throw KeeperFailure("Desktop UUID is missing.") }
            number += 1
            desktops.append(KeeperDesktop(display: display, number: number, uuid: uuid))
        }
        guard number > 0 else { throw KeeperFailure("No ordinary Desktops found on a display.") }
    }
    guard Set(desktops.map { "\($0.display)|\($0.number)" }).count == desktops.count else {
        throw KeeperFailure("Ambiguous display groups. No assignments written.")
    }
    return KeeperSnapshot(displays: displays.sorted { $0.id < $1.id },
        desktops: desktops.sorted { ($0.display, $0.number) < ($1.display, $1.number) }, bindings: bindings)
}
protocol KeeperPreferences {
    func read() throws -> KeeperSnapshot
    func setBinding(_ bundle: String, _ target: String) throws
}
struct SystemKeeperPreferences: KeeperPreferences {
    // Only tests pass an isolated domain. The production domain is fixed.
    var domain = "com.apple.spaces"
    var displayProvider: () throws -> [KeeperDisplay] = keeperDisplays
    func read() throws -> KeeperSnapshot {
        let data = try keeperCommand("/usr/bin/defaults", ["export", domain, "-"])
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw KeeperFailure("Cannot read Spaces preferences.")
        }
        return try keeperParse(root, displays: displayProvider())
    }
    func setBinding(_ bundle: String, _ target: String) throws {
        guard bundle.range(of: "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)+$", options: .regularExpression) != nil else {
            throw KeeperFailure("Unsupported application identifier: \(bundle)")
        }
        _ = try keeperCommand("/usr/bin/defaults", ["write", domain, "app-bindings", "-dict-add", bundle, target])
    }
}
func keeperCapture(_ snapshot: KeeperSnapshot, name: (String) -> String) throws -> KeeperBackup {
    guard !snapshot.bindings.isEmpty else { throw KeeperFailure("No application assignments to save. Arrange applications using Dock first.") }
    let assignments = try snapshot.bindings.keys.sorted().map { bundle -> KeeperAssignment in
        let matches = snapshot.desktops.filter { $0.uuid == snapshot.bindings[bundle]! }
        guard matches.count == 1 else {
            throw KeeperFailure("\(bundle) has an unknown or ambiguous destination. Set an explicit Desktop in Dock before saving.")
        }
        return KeeperAssignment(bundleID: bundle, name: name(bundle), target: matches[0])
    }
    return KeeperBackup(formatVersion: 1, savedAt: Date(), snapshot: snapshot, assignments: assignments)
}
func keeperValidate(_ backup: KeeperBackup, current: KeeperSnapshot) throws {
    guard backup.formatVersion == 1 else { throw KeeperFailure("Unsupported backup version. Backup preserved.") }
    guard !backup.assignments.isEmpty,
          Set(backup.assignments.map(\.bundleID)).count == backup.assignments.count,
          backup.assignments.count == backup.snapshot.bindings.count,
          backup.assignments.allSatisfy({ backup.snapshot.desktops.contains($0.target) && backup.snapshot.bindings[$0.bundleID] == $0.target.uuid }) else {
        throw KeeperFailure("Backup contents are inconsistent. No assignments written.")
    }
    guard backup.snapshot.sameDestinations(as: current) else {
        throw KeeperFailure("Desktop configuration has changed. Display identity, mirroring, UUIDs or Desktop order no longer matches the backup. Review the layout and explicitly save again; no UUIDs will be guessed.")
    }
}
final class KeeperEngine {
    let preferences: KeeperPreferences
    let directory: URL
    init(preferences: KeeperPreferences = SystemKeeperPreferences(), directory: URL = keeperDirectory) {
        self.preferences = preferences; self.directory = directory
    }
    var backupURL: URL { directory.appendingPathComponent("config.json") }
    func load() throws -> KeeperBackup {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { throw KeeperFailure("No saved configuration available.") }
        return try keeperDecode(KeeperBackup.self, Data(contentsOf: backupURL))
    }
    func save() throws -> KeeperBackup {
        let lock = try KeeperLock(directory.appendingPathComponent("repair.lock"))
        defer { withExtendedLifetime(lock) {} }
        let first = try preferences.read()
        let backup = try keeperCapture(first) { bundle in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        guard first == (try preferences.read()) else { throw KeeperFailure("Configuration changed during capture. Try saving again when stable.") }
        if FileManager.default.fileExists(atPath: backupURL.path) {
            // Explicit saving keeps one recovery copy; automatic repair never saves.
            let previous = try Data(contentsOf: backupURL)
            try previous.write(to: directory.appendingPathComponent("config.previous.json"), options: .atomic)
        }
        try keeperWrite(backup, backupURL)
        return backup
    }
    func restore(allowed: () throws -> Bool = { true }) throws -> KeeperReport {
        let lock = try KeeperLock(directory.appendingPathComponent("repair.lock"))
        defer { withExtendedLifetime(lock) {} }
        let backup = try load()
        let initial = try preferences.read()
        try keeperValidate(backup, current: initial)
        var expected = initial.bindings
        var count = 0
        for entry in backup.assignments {
            let before = try preferences.read()
            try keeperValidate(backup, current: before)
            guard before.displays == initial.displays else { throw KeeperFailure("Display mode changed during repair. Retry after settling.") }
            let actual = before.bindings[entry.bundleID]
            if actual == entry.target.uuid { continue }
            guard actual == expected[entry.bundleID] else {
                throw KeeperFailure("\(entry.name)'s assignment changed during repair. Stopped to preserve concurrent edits.")
            }
            // Preserve unrelated current bindings. Never replace the dictionary/domain.
            guard try allowed() else { throw KeeperFailure("Automatic restoration was disabled; remaining writes cancelled.") }
            try preferences.setBinding(entry.bundleID, entry.target.uuid)
            let after = try preferences.read()
            try keeperValidate(backup, current: after)
            guard after.bindings[entry.bundleID] == entry.target.uuid else { throw KeeperFailure("Could not verify \(entry.name)'s assignment. No retry loop started.") }
            for (bundle, value) in before.bindings where bundle != entry.bundleID {
                guard after.bindings[bundle] == value else {
                    throw KeeperFailure("Another assignment changed during repair. Stopped without replacing or rolling back the preferences dictionary.")
                }
            }
            expected[entry.bundleID] = entry.target.uuid
            count += 1
        }
        let final = try preferences.read()
        try keeperValidate(backup, current: final)
        guard backup.assignments.allSatisfy({ final.bindings[$0.bundleID] == $0.target.uuid }) else {
            throw KeeperFailure("Assignments changed before final verification. Manual review required.")
        }
        return KeeperReport(restored: count, verified: backup.assignments.count,
            message: "\(count) assignments restored; \(backup.assignments.count) verified. Existing windows were not moved.")
    }
}
func keeperDiagnosticRecord(_ key: String, _ message: String) {
    let url = keeperDirectory.appendingPathComponent("diagnostics.json")
    do {
        var entries = (try? keeperDecode([String: String].self, Data(contentsOf: url))) ?? [:]
        entries[key] = "\(ISO8601DateFormatter().string(from: Date())) — \(message)"
        if key == "lastError" {
            let recent = (entries["recentErrors"] ?? "").split(separator: "\n").map(String.init)
            entries["recentErrors"] = (recent + [entries[key]!]).suffix(12).joined(separator: "\n")
        }
        try keeperWrite(entries, url)
    } catch { NSLog("SpacesKeeper could not persist diagnostics") }
}
func keeperStatus() throws -> Data {
    let engine = KeeperEngine()
    let current = try engine.preferences.read()
    var state = "No saved configuration available"
    var missing: [String] = [], different: [String] = []
    let saved: KeeperBackup?
    if FileManager.default.fileExists(atPath: engine.backupURL.path) {
        saved = try engine.load()
        do {
            try keeperValidate(saved!, current: current)
            for entry in saved!.assignments {
                if current.bindings[entry.bundleID] == nil { missing.append(entry.bundleID) }
                else if current.bindings[entry.bundleID] != entry.target.uuid { different.append(entry.bundleID) }
            }
            state = !different.isEmpty ? "Assignments differ from backup" : !missing.isEmpty ? "Missing assignments detected" : "Configuration matches backup"
        } catch { state = error.localizedDescription }
    } else { saved = nil }
    struct Status: Encodable {
        let status: String; let macOS: String; let options: KeeperOptions
        let current: KeeperSnapshot; let saved: KeeperBackup?
        let missing: [String]; let different: [String]; let diagnostics: [String: String]
    }
    let diagnostics = (try? keeperDecode([String:String].self, Data(contentsOf: keeperDirectory.appendingPathComponent("diagnostics.json")))) ?? [:]
    return try keeperEncode(Status(status: state, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
        options: keeperOptions(), current: current, saved: saved, missing: missing, different: different, diagnostics: diagnostics))
}
// CLI returns before registering observers or triggering Dock; no competing agent.
func keeperCLI(_ arguments: [String]) throws -> Bool {
    guard let command = arguments.first else { return false }
    switch command {
    case "--request-dock-restart":
        guard arguments.count == 1 else { throw KeeperFailure("Usage: --request-dock-restart") }
        try keeperWrite(Date(), keeperDirectory.appendingPathComponent("manual-dock-request.json"))
        print("Dock restart requested. The running helper will wait for a ready desktop and coalesce overlapping requests.")
    case "--dock-delay":
        guard arguments.count == 2, let delay = Double(arguments[1]), delay.isFinite, (1...60).contains(delay) else {
            throw KeeperFailure("Dock delay must be 1–60 seconds.")
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SpacesWakeFix/settings.json")
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any] ?? [:]
        settings["delay"] = delay
        try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        print("Dock restart delay updated.")
    case "--save-assignments":
        guard arguments.count == 1 else { throw KeeperFailure("Usage: --save-assignments") }
        let backup = try KeeperEngine().save()
        print("Saved \(backup.assignments.count) assignments. Automatic events never overwrite this backup.")
    case "--restore-assignments":
        guard arguments.count == 1 else { throw KeeperFailure("Usage: --restore-assignments") }
        let result = try KeeperEngine().restore()
        keeperDiagnosticRecord("lastRestoration", result.message)
        print(result.message)
    case "--health":
        guard arguments.count == 1 else { throw KeeperFailure("Usage: --health") }
        let data = try Data(contentsOf: keeperDirectory.appendingPathComponent("diagnostics.json"))
        let diagnostics = try keeperDecode([String:String].self, data)
        print(String(decoding: try keeperEncode(diagnostics), as: UTF8.self))
    case "--spaces-status":
        guard arguments.count == 1 else { throw KeeperFailure("Usage: --spaces-status") }
        print(String(decoding: try keeperStatus(), as: UTF8.self))
    case "--assignment-repair", "--dock-workaround", "--restore-on-display", "--restore-after-wake", "--restore-at-login", "--restoration-delay":
        guard arguments.count == 2 else { throw KeeperFailure("Supply on/off, or seconds for --restoration-delay.") }
        let lock = try KeeperLock(keeperDirectory.appendingPathComponent("repair.lock"))
        defer { withExtendedLifetime(lock) {} }
        var options = try keeperOptions()
        if command == "--restoration-delay" {
            guard let seconds = Double(arguments[1]), seconds.isFinite, (1...60).contains(seconds) else { throw KeeperFailure("Delay must be 1–60 seconds.") }
            options.restorationDelay = seconds
        } else {
            guard ["on", "off"].contains(arguments[1]) else { throw KeeperFailure("Use on or off.") }
            let enabled = arguments[1] == "on"
            switch command {
            case "--assignment-repair": options.automaticRestoration = enabled
            case "--dock-workaround": options.dockWorkaround = enabled
            case "--restore-on-display": options.restoreOnDisplay = enabled
            case "--restore-after-wake": options.restoreAfterWake = enabled
            default: options.restoreAtLogin = enabled
            }
        }
        try keeperWrite(options, keeperDirectory.appendingPathComponent("settings.json"))
        print("Saved setting; the running helper reads it on the next event and before pending repairs.")
    default: return false
    }
    return true
}
