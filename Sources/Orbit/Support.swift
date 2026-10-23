import AppKit

/// Small blocking prompts for actions that need one value (a password, a page range).
/// Actions run off the main thread, so the prompt hops to main and waits there.
enum Ask {
    /// Tests set this to answer prompts without UI.
    nonisolated(unsafe) static var answer: ((String) -> String?)?

    static func text(_ title: String, _ message: String, placeholder: String = "", secure: Bool = false) throws -> String {
        if let answer {
            guard let v = answer(title) else { throw OrbitError("Cancelled") }
            return v
        }
        var result: String?
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { RingController.shared.hideForPrompt() }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            field.placeholderString = placeholder
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { result = field.stringValue }
        }
        guard let r = result, !r.trimmingCharacters(in: .whitespaces).isEmpty else { throw OrbitError("Cancelled") }
        return r
    }

    /// "1,3-5" -> [0, 2, 3, 4] (zero-based, within 0..<count).
    static func pages(_ spec: String, count: Int) throws -> [Int] {
        var out: [Int] = []
        for part in spec.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let a = bounds.first, (1...count).contains(a) else { throw OrbitError("Page \(part) is not in 1-\(count)") }
            let b = bounds.count > 1 ? bounds[1] : a
            guard (a...count).contains(b) else { throw OrbitError("Page \(part) is not in 1-\(count)") }
            out += (a...b).map { $0 - 1 }
        }
        return Array(Set(out)).sorted()
    }

    /// "5" or "00:05" or "1:02:03" -> seconds.
    static func seconds(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}

/// Undo for the last action: outputs go to the Trash, renames go back.
@MainActor
enum UndoStore {
    private static var undo: (() -> Void)?
    private(set) static var label: String?

    static func record(_ label: String, _ f: @escaping () -> Void) { undo = f; self.label = label }
    static func recordOutputs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        record(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files") {
            for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        }
    }
    static func run() { undo?(); undo = nil; label = nil }
}

/// Remembers the last segment used per file kind, so the ring opens where you left it.
enum Usage {
    static func lastSegment(for kind: FileKind) -> String? { UserDefaults.standard.string(forKey: "lastSegment.\(kind.rawValue)") }
    static func use(segment: String, kind: FileKind) { UserDefaults.standard.set(segment, forKey: "lastSegment.\(kind.rawValue)") }
}

/// Per-file progress for batch actions; RingModel listens while an action runs.
enum RunProgress {
    nonisolated(unsafe) static var report: ((Int, Int) -> Void)?
}
