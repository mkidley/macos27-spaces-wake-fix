import AppKit
import SwiftUI
@main struct RenderUI {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let displays = [KeeperDisplay(id: "example-display", mirrorOf: nil, main: true, width: 6144, height: 2560)]
        let desktops = (1...4).map { KeeperDesktop(display: "example-display", number: $0, uuid: $0 == 1 ? "" : "example-space-\($0)") }
        let snapshot = KeeperSnapshot(displays: displays, desktops: desktops, bindings: ["com.google.chrome": desktops[1].uuid, "com.apple.mail": desktops[3].uuid])
        let saved = try keeperCapture(snapshot) { $0 == "com.apple.mail" ? "Mail" : "Google Chrome" }
        let model = KeeperModel()
        var options = KeeperOptions(); options.automaticRestoration = true
        model.status = AppStatus(status: "Configuration matches backup", macOS: "macOS 27", options: options, current: snapshot, saved: saved, missing: [], different: [], diagnostics: [:])
        model.message = "Configuration matches backup"; model.legacyRunning = true
        model.diagnostics = String(decoding: try keeperEncode(snapshot), as: UTF8.self)
        let views: [(String, AnyView, NSSize)] = [
            ("configuration", AnyView(ConfigurationView(model: model)), NSSize(width: 740, height: 700)),
            ("settings", AnyView(KeeperSettingsView(model: model)), NSSize(width: 590, height: 680)),
            ("diagnostics", AnyView(DiagnosticsView(model: model)), NSSize(width: 850, height: 600))
        ]
        var windows: [NSWindow] = []
        for (_, view, size) in views {
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false; window.orderFront(nil); windows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            do {
                for (index, window) in windows.enumerated() {
                    guard let view = window.contentView else { fatalError("Missing view") }
                    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Render failed") }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(views[index].0).png"))
                }
                print("Rendered native configuration, settings and diagnostics views using synthetic assignments.")
                app.terminate(nil)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
