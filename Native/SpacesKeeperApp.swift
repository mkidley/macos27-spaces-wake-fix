import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

func appCommand(_ executable: String, _ arguments: [String]) throws -> Data {
    let process = Process(); let output = Pipe(); let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = output; process.standardError = errors
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    let problem = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let text = String(decoding: problem, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw KeeperFailure(text.isEmpty ? "Command failed (\(process.terminationStatus))." : text)
    }
    return bytes
}
struct AppStatus: Decodable {
    let status: String
    let macOS: String
    let options: KeeperOptions
    let current: KeeperSnapshot
    let saved: KeeperBackup?
    let missing: [String]
    let different: [String]
    let diagnostics: [String: String]
}
struct InterfaceSettings: Codable { var showMenuBarIcon = true }
struct NativeOwnership: Codable { let bundlePath: String; let activatedAt: Date }

@MainActor final class KeeperModel: ObservableObject {
    @Published var status: AppStatus?
    @Published var busy = false
    @Published var message = "Reading Spaces configuration…"
    @Published var diagnostics = ""
    @Published var ownsHelper = false
    @Published var helperRunning = false
    @Published var legacyRunning = false
    @Published var showMenu = true
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var dockDelay: Double = 5
    weak var delegate: KeeperDelegate?
    let legacyBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SpacesWakeFix")
    var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/spaces-wake-fix") }
    var ownerURL: URL { keeperDirectory.appendingPathComponent("native-owner.json") }
    var legacyPlist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/org.spaceswakefix.agent.plist") }
    var parkedPlist: URL { keeperDirectory.appendingPathComponent("legacy-agent.plist") }
    var domain: String { "gui/\(getuid())" }
    private var instanceLock: KeeperLock?
    private var helper: Process?
    private var helperToken = UUID()
    private var stopping = false
    private var registeredForMigration = false
    private var failureTimes: [Date] = []
    private var lastError: String?
    private var lastRecord: Data?
    private var poller: Timer?

    func initialize() throws {
        instanceLock = try KeeperLock(keeperDirectory.appendingPathComponent("app.lock"))
        try keeperPrepare(legacyBase)
        if !FileManager.default.fileExists(atPath: legacyBase.appendingPathComponent("settings.json").path) {
            _ = try appCommand(helperURL.path, ["--configure", "5", "true"])
        }
        showMenu = (try? keeperDecode(InterfaceSettings.self, Data(contentsOf: keeperDirectory.appendingPathComponent("interface.json"))))?.showMenuBarIcon ?? true
        let recordURL = keeperDirectory.appendingPathComponent("diagnostics.json")
        lastError = (try? keeperDecode([String:String].self, Data(contentsOf: recordURL)))?["lastError"]
        ownsHelper = FileManager.default.fileExists(atPath: ownerURL.path)
        legacyRunning = serviceIsRunning()
        updateLoginStatus()
        if ownsHelper && !legacyRunning { try startHelper() }
        else if ownsHelper && legacyRunning {
            message = "The legacy agent is active. Repair ownership must be resolved before starting another helper."
        }
        refresh()
        poller = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.pollDiagnostics() }
        }
    }
    func serviceIsRunning() -> Bool {
        (try? appCommand("/bin/launchctl", ["print", "\(domain)/org.spaceswakefix.agent"])) != nil
    }
    func updateLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            updateLoginStatus()
        } catch { showError(error) }
    }
    func setMenu(_ enabled: Bool) {
        do {
            try keeperWrite(InterfaceSettings(showMenuBarIcon: enabled), keeperDirectory.appendingPathComponent("interface.json"))
            showMenu = enabled
            delegate?.updateMenuVisibility()
        } catch { showError(error) }
    }
    func pollDiagnostics() {
        let data = try? Data(contentsOf: keeperDirectory.appendingPathComponent("diagnostics.json"))
        if data != lastRecord {
            lastRecord = data
            if let data, let entries = try? keeperDecode([String:String].self, data),
               let error = entries["lastError"], error != lastError {
                lastError = error
                if ownsHelper { notifyFailure(error) }
            }
            refresh()
        }
        updateLoginStatus()
    }
    func refresh() {
        guard !busy else { return }
        run(["--spaces-status"], silent: true) { [weak self] data in
            guard let self else { return }
            let parsed = try JSONDecoderWithDates.decode(AppStatus.self, from: data)
            self.status = parsed
            self.diagnostics = String(decoding: data, as: UTF8.self)
            self.message = parsed.status
            if let bytes = try? Data(contentsOf: self.legacyBase.appendingPathComponent("settings.json")),
               let dictionary = try? JSONSerialization.jsonObject(with: bytes) as? [String:Any],
               let delay = dictionary["delay"] as? Double { self.dockDelay = delay }
            self.legacyRunning = self.serviceIsRunning()
            self.delegate?.refreshMenu()
        }
    }
    func run(_ arguments: [String], silent: Bool = false, completion: ((Data) throws -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        let executable = helperURL.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try appCommand(executable, arguments) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                do {
                    let data = try result.get()
                    if let completion { try completion(data) }
                    else {
                        self.message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !silent { self.inform(self.message) }
                        self.refresh()
                    }
                } catch {
                    self.message = error.localizedDescription
                    if !silent { self.showError(error) }
                    self.delegate?.refreshMenu()
                }
            }
        }
    }
    func setting(_ flag: String, _ enabled: Bool) { run([flag, enabled ? "on" : "off"], silent: true) }
    func delay(_ flag: String, _ seconds: Double) { run([flag, String(Int(seconds))], silent: true) }
    func save() {
        guard confirm("Save current configuration?", "Arrange assignments in Dock first. This explicitly replaces the saved configuration with the current assignments. One previous backup is retained.", action: "Save Configuration") else { return }
        run(["--save-assignments"])
    }
    func restore() { run(["--restore-assignments"]) }
    func restartDock() {
        guard ownsHelper, helperRunning else {
            inform("Start SpacesKeeper repairs first. The legacy service remains responsible for the Dock workaround in preview mode."); return
        }
        run(["--request-dock-restart"])
    }
    func startHelper() throws {
        guard helper == nil, !serviceIsRunning() else { throw KeeperFailure("Another repair helper is already active.") }
        stopping = false
        let process = Process()
        let token = UUID(); helperToken = token
        process.executableURL = helperURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.helperToken == token else { return }
                self.helper = nil; self.helperRunning = false
                guard !self.stopping && self.ownsHelper else { return }
                self.message = "Repair helper exited (\(code))."
                self.notifyFailure(self.message)
                self.failureTimes = self.failureTimes.filter { Date().timeIntervalSince($0) < 60 }
                self.failureTimes.append(Date())
                if self.failureTimes.count <= 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        guard !self.stopping, self.ownsHelper, self.helper == nil else { return }
                        do { try self.startHelper() } catch { self.message = error.localizedDescription }
                    }
                }
            }
        }
        try process.run()
        helper = process; helperRunning = true
    }
    func stopHelper() {
        stopping = true; helperToken = UUID()
        if let helper, helper.isRunning {
            helper.terminate()
            let deadline = Date().addingTimeInterval(3)
            while helper.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if helper.isRunning { kill(helper.processIdentifier, SIGKILL); helper.waitUntilExit() }
        }
        helper = nil; helperRunning = false
    }
    func activate() {
        guard !busy else { return }
        guard confirm("Start SpacesKeeper repairs?", "SpacesKeeper will manage the tested helper and launch at login. The old LaunchAgent will be stopped and retained for rollback. No second repair process will run.", action: "Start Repairs") else { return }
        do {
            // Registration/approval precedes disabling the working service.
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register(); registeredForMigration = true
            }
            updateLoginStatus()
            guard SMAppService.mainApp.status == .enabled else {
                inform("Approve SpacesKeeper in System Settings → General → Login Items, then click Start Repairs again. The existing service remains active.")
                SMAppService.openSystemSettingsLoginItems(); return
            }
            if FileManager.default.fileExists(atPath: legacyPlist.path) && FileManager.default.fileExists(atPath: parkedPlist.path) {
                throw KeeperFailure("Both legacy plist locations exist. The running service was left untouched.")
            }
            busy = true
            let startedAt = Date()
            if serviceIsRunning() { _ = try appCommand("/bin/launchctl", ["bootout", "\(domain)/org.spaceswakefix.agent"]) }
            if FileManager.default.fileExists(atPath: legacyPlist.path) {
                guard !FileManager.default.fileExists(atPath: parkedPlist.path) else { throw KeeperFailure("A previous agent backup already exists. Resolve it before migration.") }
                try FileManager.default.moveItem(at: legacyPlist, to: parkedPlist)
            }
            try startHelper()
            // A native owner is committed only after the replacement responds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                do {
                    guard self.helper?.isRunning == true else { throw KeeperFailure("The replacement helper did not remain running.") }
                    let health = try keeperDecode([String:String].self, appCommand(self.helperURL.path, ["--health"]))
                    guard let startText = health["lastStart"]?.components(separatedBy: " — ").first,
                          let started = ISO8601DateFormatter().date(from: startText), started >= startedAt.addingTimeInterval(-1) else {
                        throw KeeperFailure("The replacement helper did not report a fresh startup. Returning to the previous service.")
                    }
                    try keeperWrite(NativeOwnership(bundlePath: Bundle.main.bundleURL.path, activatedAt: Date()), self.ownerURL)
                    let removal = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/uninstall-app.sh")
                    let removalTarget = self.legacyBase.appendingPathComponent("uninstall.sh")
                    try Data(contentsOf: removal).write(to: removalTarget, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: removalTarget.path)
                    self.ownsHelper = true; self.legacyRunning = false; self.registeredForMigration = false
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
                    self.busy = false; self.message = "SpacesKeeper is managing repairs. Previous agent retained for rollback."
                    self.refresh()
                } catch { self.recoverMigration(error) }
            }
        } catch { recoverMigration(error) }
    }
    func recoverMigration(_ error: Error) {
        stopHelper(); busy = false
        if registeredForMigration {
            do { try SMAppService.mainApp.unregister(); registeredForMigration = false }
            catch { message = "Could not unregister the new login item: \(error.localizedDescription)" }
            updateLoginStatus()
        }
        do { try restoreLegacyAgent() } catch { message = "Migration and rollback need attention: \(error.localizedDescription)" }
        showError(error)
    }
    func restoreLegacyAgent() throws {
        if FileManager.default.fileExists(atPath: parkedPlist.path) {
            guard !FileManager.default.fileExists(atPath: legacyPlist.path) else { throw KeeperFailure("Both legacy plist locations exist; neither was overwritten.") }
            try FileManager.default.moveItem(at: parkedPlist, to: legacyPlist)
        }
        if FileManager.default.fileExists(atPath: legacyPlist.path), !serviceIsRunning() {
            _ = try appCommand("/bin/launchctl", ["bootstrap", domain, legacyPlist.path])
        }
        if FileManager.default.fileExists(atPath: ownerURL.path) { try FileManager.default.removeItem(at: ownerURL) }
        ownsHelper = false; legacyRunning = serviceIsRunning()
    }
    func retryHelper() {
        guard ownsHelper, helper == nil else { return }
        failureTimes.removeAll()
        do { try startHelper() } catch { showError(error) }
    }
    func rollback() {
        guard confirm("Return to the previous LaunchAgent?", "SpacesKeeper will stop its helper and disable its login item, then restore the previous agent. Saved assignments remain intact.", action: "Restore Agent") else { return }
        do {
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            stopHelper(); try restoreLegacyAgent(); updateLoginStatus(); refresh()
        } catch { showError(error) }
    }
    func uninstall() {
        guard confirm("Uninstall SpacesKeeper and the old workaround?", "This stops repairs and removes both support directories, saved backups, the LaunchAgent and this app. Actual macOS assignments are unchanged. Copy any backup you want to keep first.", action: "Uninstall") else { return }
        do {
            let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/SpacesKeeper.app")
            guard Bundle.main.bundleURL.standardizedFileURL == expected.standardizedFileURL else {
                throw KeeperFailure("Automatic app removal is supported only from ~/Applications/SpacesKeeper.app. Use the documented manual uninstall for other locations.")
            }
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            stopHelper()
            if serviceIsRunning() { _ = try appCommand("/bin/launchctl", ["bootout", "\(domain)/org.spaceswakefix.agent"]) }
            for path in [legacyPlist, legacyBase, keeperDirectory] where FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
            try FileManager.default.removeItem(at: expected)
            NSApp.terminate(nil)
        } catch { showError(error) }
    }
    func confirm(_ title: String, _ detail: String, action: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
    func inform(_ text: String) {
        let alert = NSAlert(); alert.messageText = "SpacesKeeper"; alert.informativeText = text
        alert.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    func showError(_ error: Error) { message = error.localizedDescription; inform(message) }
    func notifyFailure(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "SpacesKeeper needs attention"; content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "repair-failure", content: content, trigger: nil), withCompletionHandler: nil)
    }
    func copyDiagnostics() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics, forType: .string)
    }
    func shutdown() { poller?.invalidate(); stopHelper() }
}
// Shares exactly the backup date format used by the command-line engine.
enum JSONDecoderWithDates {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try keeperDecode(type, data) }
}

@MainActor struct ConfigurationView: View {
    @ObservedObject var model: KeeperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "rectangle.3.group").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("SpacesKeeper").font(.title.bold())
                    Text("Keep your application assignments where you saved them.").foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh configuration").disabled(model.busy)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.message, systemImage: model.status?.status == "Configuration matches backup" ? "checkmark.circle.fill" : "info.circle")
                    if !model.ownsHelper {
                        Text(model.legacyRunning ? "Preview: the existing LaunchAgent still runs your repairs." : "Repairs are not yet managed by this app.").foregroundStyle(.secondary)
                        Button("Start SpacesKeeper Repairs…") { model.activate() }.disabled(model.busy)
                    } else {
                        Text(model.helperRunning ? "Repair helper is running" : "Repair helper needs attention").foregroundStyle(.secondary)
                        if !model.helperRunning { Button("Restart Repair Helper") { model.retryHelper() } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let saved = model.status?.saved {
                        ForEach(Array(saved.snapshot.desktops.enumerated()), id: \.offset) { _, desktop in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Desktop \(desktop.number)").font(.headline)
                                    if saved.snapshot.displays.count > 1 {
                                        Text("Display \((saved.snapshot.displays.firstIndex(where: { $0.id == desktop.display }) ?? 0) + 1)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    let apps = saved.assignments.filter { $0.target == desktop }
                                    if apps.isEmpty { Text("No saved application assignments").foregroundStyle(.secondary) }
                                    ForEach(apps, id: \.bundleID) { entry in
                                        HStack(spacing: 10) {
                                            AppIcon(bundle: entry.bundleID)
                                            Text(entry.name)
                                            Spacer()
                                            if model.status?.missing.contains(entry.bundleID) == true { Text("Missing").foregroundStyle(.orange) }
                                            else if model.status?.different.contains(entry.bundleID) == true { Text("Different").foregroundStyle(.orange) }
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                        Text("Last saved: \(saved.savedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No saved configuration").font(.headline)
                            Text("Assign applications to Desktops using the normal Dock menu, then save the configuration here.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(30)
                    }
                }
            }
            HStack {
                Button("Save Current Configuration…") { model.save() }
                Button("Restore Saved Configuration") { model.restore() }.buttonStyle(.borderedProminent).disabled(model.status?.saved == nil)
                Spacer()
                Button("Settings…") { model.delegate?.showSettings() }
            }.disabled(model.busy)
            Text("Restoring assignments does not move existing windows. macOS can apply the assignment when an application is next launched.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 660, minHeight: 540).background(Color(nsColor: .windowBackgroundColor))
    }
}
@MainActor struct AppIcon: View {
    let bundle: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
        } else { Image(systemName: "app").frame(width: 24, height: 24) }
    }
}
@MainActor struct KeeperSettingsView: View {
    @ObservedObject var model: KeeperModel
    var options: KeeperOptions { model.status?.options ?? KeeperOptions() }
    func binding(_ flag: String, _ value: Bool) -> Binding<Bool> { Binding(get: { value }, set: { model.setting(flag, $0) }) }
    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })).disabled(!model.ownsHelper && !model.loginEnabled)
                if model.loginNeedsApproval { Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() } }
                Toggle("Show Menu Bar Icon", isOn: Binding(get: { model.showMenu }, set: { model.setMenu($0) }))
                Text("When the menu bar icon is hidden, SpacesKeeper appears in the Dock. You can always reopen it from Applications.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Spaces Assignment Repair") {
                Toggle("Enable Automatic Spaces Restoration", isOn: binding("--assignment-repair", options.automaticRestoration))
                Toggle("Restore on Display Connection", isOn: binding("--restore-on-display", options.restoreOnDisplay))
                Toggle("Restore After Wake", isOn: binding("--restore-after-wake", options.restoreAfterWake))
                Toggle("Restore at Login / Startup", isOn: binding("--restore-at-login", options.restoreAtLogin))
                Stepper("Restoration Delay: \(Int(options.restorationDelay)) seconds", value: Binding(get: { options.restorationDelay }, set: { model.delay("--restoration-delay", $0) }), in: 1...60)
                Text("Waits for an unlocked, stable display configuration. Changed or ambiguous Desktop layouts are never guessed.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Mission Control Keyboard Shortcut Fix") {
                Toggle("Enable Dock Restart Workaround", isOn: binding("--dock-workaround", options.dockWorkaround))
                Stepper("Dock Restart Delay: \(Int(model.dockDelay)) seconds", value: Binding(get: { model.dockDelay }, set: { model.delay("--dock-delay", $0) }), in: 1...60).disabled(!model.ownsHelper)
                Text("Independent of assignment repair. When both are enabled, assignment repair runs first after the longer settling delay.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Maintenance") {
                Button("View Diagnostics…") { model.delegate?.showDiagnostics() }
                if model.ownsHelper { Button("Return to Previous LaunchAgent…") { model.rollback() } }
                Button("Uninstall SpacesKeeper…", role: .destructive) { model.uninstall() }
            }
        }.formStyle(.grouped).padding(8).frame(width: 570, height: 630).disabled(model.busy)
    }
}
@MainActor struct DiagnosticsView: View {
    @ObservedObject var model: KeeperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnostics").font(.title2.bold()); Spacer()
                Button("Refresh") { model.refresh() }.disabled(model.busy)
                Button("Copy Diagnostics") { model.copyDiagnostics() }
                Button("Open Console") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")) }
            }
            Text("Console filter: org.spaceswakefix.agent. Diagnostics include application names and display identifiers; review before sharing.").font(.caption).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(model.diagnostics).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(10).background(Color(nsColor: .textBackgroundColor)).cornerRadius(6)
        }.padding(20).frame(minWidth: 700, minHeight: 500).background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor final class KeeperDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let model = KeeperModel()
    private var item: NSStatusItem?
    private var windows: [String: NSWindow] = [:]
    private var signalSource: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.delegate = self
        installApplicationMenu()
        do { try model.initialize() }
        catch {
            if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "org.spaceskeeper.app").first(where: { $0.processIdentifier != getpid() }) {
                other.activate(options: [.activateAllWindows])
            } else { model.inform(error.localizedDescription) }
            NSApp.terminate(nil); return
        }
        UNUserNotificationCenter.current().delegate = self
        updateMenuVisibility()
        // Login launches stay in the menu bar once ownership is established.
        if !model.ownsHelper || !model.showMenu { showConfiguration() }
        signal(SIGTERM, SIG_IGN)
        signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signalSource?.setEventHandler { NSApp.terminate(nil) }; signalSource?.resume()
    }
    func installApplicationMenu() {
        let main = NSMenu()
        let application = NSMenu(); let appRoot = NSMenuItem(); appRoot.submenu = application; main.addItem(appRoot)
        application.addItem(withTitle: "About SpacesKeeper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        application.addItem(.separator())
        let settings = application.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        application.addItem(withTitle: "Hide SpacesKeeper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(.separator())
        application.addItem(withTitle: "Quit SpacesKeeper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit"); let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); editRoot.submenu = edit; main.addItem(editRoot)
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = main
    }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showConfiguration(); return true }
    func updateMenuVisibility() {
        NSApp.setActivationPolicy(model.showMenu ? .accessory : .regular)
        if model.showMenu && item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "SpacesKeeper")
            item?.button?.toolTip = "SpacesKeeper"
        } else if !model.showMenu, let item { NSStatusBar.system.removeStatusItem(item); self.item = nil }
        refreshMenu()
    }
    func refreshMenu() {
        let menu = NSMenu(); menu.delegate = self
        func add(_ title: String, _ selector: Selector? = nil, enabled: Bool = true) {
            let row = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            row.target = self; row.isEnabled = enabled && selector != nil; menu.addItem(row)
        }
        menu.autoenablesItems = false
        add("SpacesKeeper")
        add("Spaces Configuration: \(model.status?.saved == nil ? "Not saved" : "Saved")")
        if let last = model.status?.diagnostics["lastRestoration"],
           let stamp = last.components(separatedBy: " — ").first,
           let date = ISO8601DateFormatter().date(from: stamp) {
            add("Last Repair: \(date.formatted(date: .omitted, time: .shortened))")
        } else { add("Last Repair: Not yet") }
        menu.addItem(.separator())
        add("Spaces Configuration…", #selector(showConfiguration))
        add("Restore Spaces Now", #selector(restore), enabled: !model.busy && model.status?.saved != nil)
        add("Save Current Configuration…", #selector(save), enabled: !model.busy)
        add("Restart Dock Now", #selector(restartDock), enabled: model.ownsHelper && model.helperRunning && !model.busy)
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings)); add("View Logs…", #selector(showDiagnostics))
        menu.addItem(.separator()); add("Quit SpacesKeeper", #selector(quit))
        item?.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) { model.refresh() }
    func showWindow(_ key: String, title: String, view: AnyView, size: NSSize) {
        let window: NSWindow
        if let existing = windows[key] { window = existing }
        else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = title; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view); window.center(); windows[key] = window
        }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    @objc func showConfiguration() { showWindow("configuration", title: "SpacesKeeper — Spaces Configuration", view: AnyView(ConfigurationView(model: model)), size: NSSize(width: 740, height: 650)) }
    @objc func showSettings() { showWindow("settings", title: "SpacesKeeper Settings", view: AnyView(KeeperSettingsView(model: model)), size: NSSize(width: 590, height: 650)) }
    @objc func showDiagnostics() { model.refresh(); showWindow("diagnostics", title: "SpacesKeeper Diagnostics", view: AnyView(DiagnosticsView(model: model)), size: NSSize(width: 850, height: 650)) }
    @objc func restore() { model.restore() }
    @objc func save() { model.save() }
    @objc func restartDock() { model.restartDock() }
    @objc func quit() { NSApp.terminate(nil) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner]) }
}
@main struct SpacesKeeperApplication {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--check") {
            do {
                guard Bundle.main.bundleIdentifier == "org.spaceskeeper.app" else { throw KeeperFailure("Invalid application bundle identifier") }
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/spaces-wake-fix")
                _ = try appCommand(helper.path, ["--self-test"])
                print("SpacesKeeper bundle and bundled helper verified."); exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--unregister-login") {
            do { if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }; exit(0) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = KeeperDelegate(); app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
