import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var model: ConvertModel?
    private var openedBeforeLaunch: URL?
    private var windowDrop: WindowDropBridge?
    private static let icon = symbol("arrow.left.arrow.right.circle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.image = Self.icon
        button.setAccessibilityLabel("Into: drop a file to convert")
        let drop = DropView(frame: button.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.app = self
        button.addSubview(drop)
        // The copies of the icon on other displays' menu bars only deliver drags to the status window.
        // Its frame is set after launch, so wait for that before registering.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let window = button.window else { return }
            self?.windowDrop = WindowDropBridge(drop: drop, window: window)
        }
        installMainMenu()
        if let url = openedBeforeLaunch { open(url) }
    }

    // Open With / drop on the app icon go through the same path as a menu-bar drop.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if statusItem?.button?.image == nil { openedBeforeLaunch = url } else { open(url) }
    }

    func open(_ url: URL) {
        window?.close()
        guard let source = Source(url: url) else {
            let alert = NSAlert()
            alert.messageText = "Into can't convert “\(url.lastPathComponent)”."
            alert.informativeText = "Supported: images, PDFs, video, audio and text documents."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let model = ConvertModel(source: source) { [weak self] _ in self?.finished() }
        let hosting = NSHostingController(rootView: ConvertView(model: model) { [weak self] in self?.window?.close() })
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Convert"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.model = model
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }

    private func finished() {
        window?.close()
        statusItem.button?.image = Self.symbol("checkmark.circle.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.statusItem.button?.image = Self.icon }
    }

    func setHighlighted(_ on: Bool) { statusItem.button?.isHighlighted = on }

    func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Convert File…", action: #selector(chooseFile), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Into", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Into")
        image?.isTemplate = true
        return image
    }

    // An accessory app has no menu bar, but text fields still need the Edit shortcuts.
    private func installMainMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Quit Into", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

/// Sits over the status-item button so files can be dropped on it.
final class DropView: NSView {
    weak var app: AppDelegate?
    private var lastDrop: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .init("com.apple.pasteboard.promised-file-url")]
                                + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    required init?(coder: NSCoder) { nil }

    private func fileURL(_ info: NSDraggingInfo) -> URL? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL
    }

    private func promise(_ info: NSDraggingInfo) -> NSFilePromiseReceiver? {
        info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])?.first as? NSFilePromiseReceiver
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileURL(sender) != nil || promise(sender) != nil else { return [] }
        MainActor.assumeIsolated { app?.setHighlighted(true) }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(sender) != nil || promise(sender) != nil ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return fileURL(sender) != nil || promise(sender) != nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { app?.setHighlighted(false) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSequenceNumber != lastDrop else { return true }
        lastDrop = sender.draggingSequenceNumber
        MainActor.assumeIsolated { app?.setHighlighted(false) }
        if let url = fileURL(sender) {
            // Let the drag session finish before a window takes focus.
            DispatchQueue.main.async { [weak self] in self?.app?.open(url) }
            return true
        }
        guard let promise = promise(sender) else { return false }
        // ponytail: promised files (Photos, Mail, Safari, screenshot thumbnails) have no folder, so they land in Downloads.
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        promise.receivePromisedFiles(atDestination: downloads, options: [:], operationQueue: .main) { [weak self] url, error in
            if error == nil { MainActor.assumeIsolated { self?.app?.open(url) } }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { app?.showMenu() }
    }
}

/// Becomes the status window's delegate to receive its drags, forwarding everything else to the original delegate.
final class WindowDropBridge: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let drop: DropView
    private weak var original: NSWindowDelegate?

    init(drop: DropView, window: NSWindow) {
        self.drop = drop
        original = window.delegate
        super.init()
        window.registerForDraggedTypes(drop.registeredDraggedTypes)
        window.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { drop.draggingEntered(sender) }
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { drop.draggingUpdated(sender) }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { drop.prepareForDragOperation(sender) }
    func draggingExited(_ sender: NSDraggingInfo?) { drop.draggingExited(sender) }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drop.performDragOperation(sender) }
}

@main
enum IntoMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") { exit(SelfTest.run()) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
