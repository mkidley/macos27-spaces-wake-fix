import Foundation

final class FakePreferences: KeeperPreferences {
    var snapshot: KeeperSnapshot
    var writes = 0
    var beforeRead: (() -> Void)?
    var corruptWrite = false
    init(_ value: KeeperSnapshot) { snapshot = value }
    func read() throws -> KeeperSnapshot { beforeRead?(); return snapshot }
    func setBinding(_ bundle: String, _ target: String) throws {
        writes += 1
        if !corruptWrite {
            var bindings = snapshot.bindings; bindings[bundle] = target
            snapshot = KeeperSnapshot(displays: snapshot.displays, desktops: snapshot.desktops, bindings: bindings)
        }
    }
}
@main struct AssignmentTests {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spaceskeeper-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var options = KeeperOptions()
        assert(!keeperSelection(options, triggers: ["wake"]).assignments)
        assert(keeperSelection(options, triggers: ["wake"]).dock)
        options.automaticRestoration = true; options.dockWorkaround = false
        assert(keeperSelection(options, triggers: ["display"]).assignments)
        assert(!keeperSelection(options, triggers: ["display"]).dock)
        options.restoreOnDisplay = false
        assert(!keeperSelection(options, triggers: ["display"]).assignments)
        assert(keeperSelection(options, triggers: ["wake"]).assignments)
        assert(keeperSelection(options, triggers: ["login"]).assignments)
        assert(!keeperSelection(options, triggers: ["login"]).dock)
        assert(keeperSelection(options, triggers: ["manual"]).dock)
        assert(!keeperSelection(options, triggers: ["manual"]).assignments)
        options.restoreAtLogin = false; options.restoreAfterWake = false
        assert(!keeperSelection(options, triggers: ["login", "wake", "display"]).assignments)
        let displays = [KeeperDisplay(id: "test-display", mirrorOf: nil, main: true, width: 5000, height: 2000)]
        let desktops = [KeeperDesktop(display: "test-display", number: 1, uuid: ""),
                        KeeperDesktop(display: "test-display", number: 2, uuid: "chrome-uuid"),
                        KeeperDesktop(display: "test-display", number: 3, uuid: "mail-uuid")]
        let bindings = ["com.google.chrome": "chrome-uuid", "com.apple.mail": "mail-uuid", "test.empty": ""]
        let snapshot = KeeperSnapshot(displays: displays, desktops: desktops, bindings: bindings)
        let fake = FakePreferences(snapshot)
        let engine = KeeperEngine(preferences: fake, directory: root)
        let backup = try engine.save()
        assert(backup.assignments.first(where: { $0.bundleID == "test.empty" })?.target.uuid == "")
        let originalBackup = try Data(contentsOf: engine.backupURL)
        func replace(_ bindings: [String: String], desktops: [KeeperDesktop]? = nil, displays: [KeeperDisplay]? = nil) {
            fake.snapshot = KeeperSnapshot(displays: displays ?? snapshot.displays, desktops: desktops ?? snapshot.desktops, bindings: bindings)
        }
        func refused(_ body: () throws -> Void) {
            do { try body(); fatalError("Unsafe operation was not refused") } catch { }
        }
        // Missing Chrome and empty-string binding, incorrect Mail, unrelated app retained.
        replace(["com.apple.mail": "chrome-uuid", "test.unrelated": ""])
        let result = try engine.restore()
        assert(result.restored == 3 && result.verified == 3)
        assert(fake.snapshot.bindings["test.empty"] == "")
        assert(fake.snapshot.bindings["test.unrelated"] == "")
        check(try engine.restore().restored == 0)
        check(try Data(contentsOf: engine.backupURL) == originalBackup)
        // Reordering, removed/recreated Desktop, changed display and mirror topology all refuse.
        let changed = [desktops[0], KeeperDesktop(display: "test-display", number: 2, uuid: "mail-uuid"), KeeperDesktop(display: "test-display", number: 3, uuid: "chrome-uuid")]
        let writes = fake.writes
        replace([:], desktops: changed); refused { _ = try engine.restore() }
        replace([:], desktops: Array(desktops.prefix(2))); refused { _ = try engine.restore() }
        replace([:], displays: [KeeperDisplay(id: "other", mirrorOf: nil, main: true, width: 5000, height: 2000)])
        refused { _ = try engine.restore() }
        replace([:], displays: [KeeperDisplay(id: "test-display", mirrorOf: "mirror", main: true, width: 5000, height: 2000)])
        refused { _ = try engine.restore() }; assert(fake.writes == writes)
        // A resolution change alone preserves destinations and permits restoration.
        replace([:], displays: [KeeperDisplay(id: "test-display", mirrorOf: nil, main: true, width: 3000, height: 1200)])
        check(try engine.restore().restored == 3)
        let secondDisplay = KeeperDisplay(id: "second", mirrorOf: nil, main: false, width: 2000, height: 1200)
        let secondDesktop = KeeperDesktop(display: "second", number: 1, uuid: "second-space")
        let multi = KeeperSnapshot(displays: (displays + [secondDisplay]).sorted { $0.id < $1.id },
            desktops: (desktops + [secondDesktop]).sorted { ($0.display, $0.number) < ($1.display, $1.number) },
            bindings: ["test.second": "second-space", "test.first": "chrome-uuid"])
        let multiBackup = try keeperCapture(multi, name: { $0 })
        assert(multiBackup.assignments.first(where: { $0.bundleID == "test.second" })?.target.display == "second")
        try keeperValidate(multiBackup, current: multi)
        refused { try keeperValidate(multiBackup, current: snapshot) }
        // Failed persistence cannot be reported as a successful restore.
        replace([:]); fake.corruptWrite = true; refused { _ = try engine.restore() }; fake.corruptWrite = false
        // User changes a planned binding after the first read: no write for that entry.
        replace([:]); var reads = 0
        fake.beforeRead = {
            reads += 1
            if reads == 2 { replace(["com.apple.mail": "new-user-choice"]) }
        }
        let count = fake.writes
        refused { _ = try engine.restore() }; assert(fake.writes == count)
        fake.beforeRead = nil
        // No backup never writes; duplicate UUIDs make capture ambiguous.
        refused { _ = try KeeperEngine(preferences: fake, directory: root.appendingPathComponent("absent")).restore() }
        refused { _ = try keeperCapture(KeeperSnapshot(displays: displays, desktops: desktops + [desktops[0]], bindings: bindings), name: { $0 }) }
        replace([:])
        let beforeDisable = fake.writes
        refused { _ = try engine.restore(allowed: { false }) }
        assert(fake.writes == beforeDisable)
        let lock = try KeeperLock(root.appendingPathComponent("repair.lock"))
        refused { _ = try engine.restore() }
        withExtendedLifetime(lock) {}
        // Exercise the real defaults preference service only in a disposable test domain.
        let domain = "org.spaceskeeper.test.\(UUID().uuidString)"
        defer { _ = try? keeperCommand("/usr/bin/defaults", ["delete", domain]) }
        let plist = root.appendingPathComponent("fixture.plist")
        let config: [String: Any] = ["SpacesDisplayConfiguration": ["Management Data": ["Monitors": [[
            "Display Identifier": "Main", "Spaces": desktops.map { ["uuid": $0.uuid, "type": 0] as [String: Any] }
        ]]]], "unrelated-preference": "keep", "app-bindings": ["test.unrelated": ""]]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: plist)
        _ = try keeperCommand("/usr/bin/defaults", ["import", domain, plist.path])
        let actual = SystemKeeperPreferences(domain: domain, displayProvider: { displays })
        let isolated = KeeperEngine(preferences: actual, directory: root.appendingPathComponent("isolated"))
        try keeperWrite(backup, isolated.backupURL)
        let realReport = try isolated.restore()
        assert(realReport.restored == 3)
        check(try actual.read().bindings["test.unrelated"] == "")
        check(try isolated.restore().restored == 0)
        let exported = try keeperCommand("/usr/bin/defaults", ["export", domain, "-"])
        let verified = try PropertyListSerialization.propertyList(from: exported, format: nil) as! [String: Any]
        assert(verified["unrelated-preference"] as? String == "keep")
        print("Assignment capture, targeted restoration, empty binding, topology refusal, concurrency, verification, persistence and isolated defaults integration passed.")
    }
}
