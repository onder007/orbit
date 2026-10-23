import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Ring window

final class RingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Hosts the ring and accepts the dragged files, so dropping onto a petal runs it.
final class DropHost: NSView {
    let model: RingModel
    init(model: RingModel, frame: NSRect) {
        self.model = model
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func track(_ info: NSDraggingInfo) -> NSDragOperation {
        let p = convert(info.draggingLocation, from: nil)
        let size = bounds.size
        MainActor.assumeIsolated { model.hit(CGPoint(x: p.x, y: size.height - p.y), in: size) }
        return .copy
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { track(info) }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { track(info) }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        _ = track(info)
        MainActor.assumeIsolated { model.fire() }
        return true
    }
}

@MainActor
final class RingController {
    static let shared = RingController()
    private var panel: RingPanel?
    private var outsideClick: Any?
    private var bag = Set<AnyCancellable>()
    var isBusy = false
    var isOpen: Bool { panel != nil }

    func show(files: [URL], at point: NSPoint, takeFocus: Bool) {
        close()
        let model = RingModel(files: files)
        guard !model.segments.isEmpty else { NSSound.beep(); return }
        model.onFinish = { [weak self] out in
            self?.isBusy = false
            if !out.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(out) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (out.isEmpty ? 2.5 : 0.7)) { self?.close() }
        }
        model.$status.sink { [weak self] s in if case .working = s { self?.isBusy = true } }.store(in: &bag)

        let size = NSSize(width: Ring.size, height: Ring.size)
        let frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        let p = RingPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // The ring is designed for light frosted glass; keep it light under a dark system theme too.
        p.appearance = NSAppearance(named: .aqua)
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in self?.close() }

        let host = DropHost(model: model, frame: NSRect(origin: .zero, size: size))
        let glass = NSVisualEffectView(frame: host.bounds)
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        let pad = Ring.size / 2 - Ring.outer.upperBound - 6
        glass.maskImage = NSImage(size: size, flipped: false) { r in
            NSBezierPath(ovalIn: r.insetBy(dx: pad, dy: pad)).fill()
            return true
        }
        let hosting = NSHostingView(rootView: RingView(model: model))
        hosting.frame = host.bounds
        host.addSubview(glass)
        host.addSubview(hosting)
        // Drops must land on DropHost, not on the SwiftUI view above it.
        hosting.unregisterDraggedTypes()
        p.contentView = host

        p.alphaValue = 0
        p.orderFrontRegardless()
        if takeFocus { NSApp.activate(ignoringOtherApps: true); p.makeKey() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p

        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in if !RingController.shared.isBusy { RingController.shared.close() } }
        }
    }

    /// Hides the ring while a prompt or editor window is up; the action keeps running.
    func hideForPrompt() {
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        panel?.orderOut(nil)
        isBusy = true
    }

    func close() {
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        panel?.orderOut(nil)
        panel = nil
        isBusy = false
        bag.removeAll()
    }
}

// MARK: - Triggers

enum Finder {
    /// Files selected in Finder (desktop included). Needs the Automation permission once.
    static func selection() -> [URL] {
        let src = """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue ?? ""
        return r.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

/// Opens the ring when a file is picked up and held near where the drag began
/// (press, nudge, pause), or at once with Shift. A quick drag away is a normal move: no ring.
/// Watches the drag pasteboard instead of mouse events, which needs no Accessibility permission.
@MainActor
final class DragWatcher {
    static let pause: TimeInterval = 0.25
    static let radius: CGFloat = 90
    private var baseline = NSPasteboard(name: .drag).changeCount
    private var shownForThisDrag = false
    private var dragStart: (at: NSPoint, time: Date)?
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    private func tick() {
        let pb = NSPasteboard(name: .drag)
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            baseline = pb.changeCount
            dragStart = nil
            if shownForThisDrag {
                shownForThisDrag = false
                // Give performDragOperation a moment; close only if nothing was dropped.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !RingController.shared.isBusy { RingController.shared.close() }
                }
            }
            return
        }
        guard !shownForThisDrag, pb.changeCount != baseline else { return }
        let now = NSEvent.mouseLocation
        guard let start = dragStart else { dragStart = (now, Date()); return }
        // A drag that left the start area is a normal file move; stop watching it.
        if start.at.distance(to: now) > Self.radius { baseline = pb.changeCount; dragStart = nil; return }
        guard NSEvent.modifierFlags.contains(.shift) || Date().timeIntervalSince(start.time) >= Self.pause else { return }
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { baseline = pb.changeCount; return }
        shownForThisDrag = true
        RingController.shared.show(files: urls, at: NSEvent.mouseLocation, takeFocus: false)
    }
}

/// Opens the ring when a file in Finder (or on the desktop) is pressed and held.
/// Global mouse monitors need no Accessibility permission; the files come from Finder's selection,
/// which Finder updates on mouse down.
@MainActor
final class LongPressWatcher {
    static let holdTime: TimeInterval = 0.45
    static let slop: CGFloat = 6
    private var monitors: [Any] = []
    private var downAt: NSPoint?
    private var timer: Timer?

    func start() {
        let watch: (NSEvent.EventTypeMask, @escaping () -> Void) -> Void = { mask, f in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in MainActor.assumeIsolated { f() } }) {
                self.monitors.append(m)
            }
        }
        watch(.leftMouseDown) { self.pressed() }
        watch(.leftMouseDragged) { if let d = self.downAt, d.distance(to: NSEvent.mouseLocation) > Self.slop { self.cancel() } }
        watch(.leftMouseUp) { self.cancel() }
    }

    private func pressed() {
        cancel()
        guard !RingController.shared.isOpen else { return }
        downAt = NSEvent.mouseLocation
        timer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { _ in
            MainActor.assumeIsolated { self.fire() }
        }
    }

    private func fire() {
        defer { cancel() }
        guard let at = downAt, NSEvent.pressedMouseButtons & 1 != 0,
              at.distance(to: NSEvent.mouseLocation) <= Self.slop,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        let files = Finder.selection()
        guard !files.isEmpty else { return }
        RingController.shared.show(files: files, at: at, takeFocus: false)
    }

    private func cancel() { timer?.invalidate(); timer = nil; downAt = nil }
}

extension NSPoint {
    func distance(to p: NSPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}

/// Global ⌥Space: ring for the current Finder selection.
final class HotKey {
    private var ref: EventHotKeyRef?
    nonisolated(unsafe) static var action: (() -> Void)?

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey)) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.action?(); return noErr }, 1, &spec, nil, nil)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x4F52_4254, id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    let drag = DragWatcher()
    let longPress = LongPressWatcher()
    var hotKey: HotKey?

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Orbit")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Ring for Finder Selection  ⌥Space", action: #selector(openRing), keyEquivalent: "")
        menu.addItem(withTitle: "Tip: hold a file and nudge it", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        undoItem = menu.addItem(withTitle: "Undo", action: #selector(undoLast), keyEquivalent: "")
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Orbit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu

        HotKey.action = { DispatchQueue.main.async { MainActor.assumeIsolated { self.openRing() } } }
        hotKey = HotKey()
        drag.start()
        longPress.start()
        // Start with the Mac, so the ring is always one press away.
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }

        // `Orbit --show <file>...` opens the ring at screen center (manual testing).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--show"), args.count > i + 1, let screen = NSScreen.main?.frame {
            let files = args[(i + 1)...].map { URL(fileURLWithPath: $0) }
            RingController.shared.show(files: files, at: NSPoint(x: screen.midX, y: screen.midY), takeFocus: true)
        }
    }

    var undoItem: NSMenuItem?

    @objc func undoLast() { UndoStore.run() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        undoItem?.title = UndoStore.label.map { "Undo \($0)" } ?? "Undo"
        undoItem?.isEnabled = UndoStore.label != nil
    }

    @objc func openRing() {
        let files = Finder.selection()
        guard !files.isEmpty else { NSSound.beep(); return }
        RingController.shared.show(files: files, at: NSEvent.mouseLocation, takeFocus: true)
    }
}

// MARK: - Entry

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest") {
    exit(SelfTest.run(dir: args.count > i + 1 ? args[i + 1] : nil))
}
if let i = args.firstIndex(of: "--run"), args.count > i + 2 {
    // --run <action id> <file>...  runs one action from the command line.
    let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
    guard let a = Catalog.segments(for: files).flatMap(\.actions).first(where: { $0.id == args[i + 1] }) else {
        print("no action \(args[i + 1]) for these files"); exit(2)
    }
    do { for u in try a.run(files) { print(u.path) }; exit(0) } catch { print("error: \(error.localizedDescription)"); exit(1) }
}
if let i = args.firstIndex(of: "--preview"), args.count > i + 2 {
    // --preview <input file> <out.png> [segment] [action]
    let seg = args.count > i + 3 ? Int(args[i + 3]) ?? 0 : 0
    let act = args.count > i + 4 ? Int(args[i + 4]) : nil
    MainActor.assumeIsolated {
        Preview.render(file: URL(fileURLWithPath: args[i + 1]), to: URL(fileURLWithPath: args[i + 2]), segment: seg, action: act)
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
