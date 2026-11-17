import AppKit
import PDFKit
import CoreText
import SwiftUI

/// `Orbit --preview <file> <out.png> [segment] [action]` renders the ring as it looks over a desktop.
@MainActor
enum Preview {
    static func render(file: URL, to out: URL, segment: Int, action: Int?) {
        let model = RingModel(files: [file])
        model.activeSegment = min(segment, max(model.segments.count - 1, 0))
        model.hoverAction = action
        model.shown = true
        let view = ZStack {
            LinearGradient(colors: [Color(red: 0.95, green: 0.33, blue: 0.30), Color(red: 0.96, green: 0.62, blue: 0.30), Color(red: 0.62, green: 0.52, blue: 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RingView(model: model)
        }
        .frame(width: Ring.size + 80, height: Ring.size + 80)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { print("render failed"); return }
        try? ImageEngine.write(cg, to: out, type: .png)
        print(out.path)
    }
}

/// `Orbit --selftest [dir]` builds fixtures and runs actions from every engine. Exit code 0 = all passed.
enum SelfTest {
    static func run(dir: String?) -> Int32 {
        let root = dir.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("orbit-selftest-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var failed = 0

        func check(_ name: String, _ body: () throws -> Bool) {
            do {
                let ok = try body()
                print((ok ? "PASS " : "FAIL ") + name)
                if !ok { failed += 1 }
            } catch {
                print("FAIL \(name): \(error.localizedDescription)"); failed += 1
            }
        }
        func size(_ u: URL) throws -> [Int] { let i = try ImageEngine.load(u).0; return [i.width, i.height] }
        func action(_ files: [URL], _ id: String) throws -> [URL] {
            guard let a = Catalog.segments(for: files).flatMap(\.actions).first(where: { $0.id == id })
            else { throw OrbitError("no action \(id)") }
            return try a.run(files)
        }

        // Fixture: 400x300 white canvas with a 200x100 red block, so trim has something to find.
        let png = root.appendingPathComponent("fixture.png")
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 100, y: 100, width: 200, height: 100))
        try? ImageEngine.write(ctx.makeImage()!, to: png, type: .png)

        check("image -> jpg") { try size(action([png], "to-jpg")[0]) == [400, 300] }
        check("image -> heic") { try action([png], "to-heic")[0].pathExtension == "heic" }
        check("image 50%") { try size(action([png], "s50")[0]) == [200, 150] }
        check("image fit 1080") { try size(action([png], "w1080")[0]) == [1080, 810] }
        check("image 9:16 fill") { try size(action([png], "story")[0]) == [1080, 1920] }
        check("image trim borders") { try size(action([png], "trim")[0]) == [200, 100] }
        check("image rotate") { try size(action([png], "rotr")[0]) == [300, 400] }
        check("image under 300 KB") { (try action([png], "under300")[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 300_000 }
        check("output never overwrites") { try action([png], "s50")[0].lastPathComponent == "fixture 50% 2.png" }

        var pdf = png
        check("images -> pdf") { pdf = try action([png, png], "img-pdf")[0]; return PDFDocument(url: pdf)?.pageCount == 2 }
        check("pdf -> png pages") { try action([pdf], "pdf-png").count == 2 }
        check("pdf split") { try action([pdf], "split").count == 2 }
        check("pdf merge") { PDFDocument(url: try action([pdf, pdf], "merge")[0])?.pageCount == 4 }
        check("pdf rotate") { PDFDocument(url: try action([pdf], "rot")[0])?.page(at: 0)?.rotation == 90 }

        let rtf = root.appendingPathComponent("note.rtf")
        let body = NSAttributedString(string: String(repeating: "Orbit converts files. ", count: 400),
                                      attributes: [.font: NSFont.systemFont(ofSize: 14)])
        try? body.rtf(from: NSRange(location: 0, length: body.length), documentAttributes: [:])?.write(to: rtf)
        check("rtf -> pdf (multi page)") { (PDFDocument(url: try action([rtf], "to-pdf")[0])?.pageCount ?? 0) >= 2 }
        check("rtf -> docx") { try action([rtf], "to-docx")[0].pathExtension == "docx" }
        check("pdf -> txt") {
            let p = try action([rtf], "to-pdf")[0]
            return try String(contentsOf: action([p], "pdf-txt")[0], encoding: .utf8).contains("Orbit")
        }

        check("prompt on the main thread throws") {
            do { _ = try Ask.text("Trim", "") } catch { return error.localizedDescription.contains("asks for input") }
            return false
        }

        // Prompts answered without UI.
        Ask.answer = { title in
            switch title {
            case "Lock PDF", "Unlock PDF": return "s3cret"
            case "Delete pages": return "1"
            case "Extract pages": return "2"
            case "Watermark": return "DRAFT"
            case "Trim": return "0:00-0:01"
            default: return title.hasPrefix("Rename") ? "renamed-{n}" : nil
            }
        }

        // Text image for OCR: dark words on white.
        let words = root.appendingPathComponent("words.png")
        let tc = CGContext(data: nil, width: 900, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        tc.setFillColor(.white); tc.fill(CGRect(x: 0, y: 0, width: 900, height: 240))
        tc.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Orbit reads this line", attributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: NSColor.black])), tc)
        try? ImageEngine.write(tc.makeImage()!, to: words, type: .png)
        check("image OCR") { try String(contentsOf: action([words], "ocr")[0], encoding: .utf8).contains("Orbit") }
        check("palette") {
            let out = try action([png], "palette")
            let hex = try String(contentsOf: out[1], encoding: .utf8)
            return out.count == 2 && hex.split(separator: "\n").count == 6
        }
        check("mac icon") { try action([png], "icns")[0].pathExtension == "icns" }
        check("favicons") { (try FileManager.default.contentsOfDirectory(atPath: action([png], "favicon")[0].path)).count == 6 }

        let note = root.appendingPathComponent("link.txt")
        try? "https://example.com".write(to: note, atomically: true, encoding: .utf8)
        check("qr code") { try size(action([note], "qr")[0])[0] > 300 }
        check("zip + unzip") {
            let z = try action([png, note], "zip")[0]
            let dir = try action([z], "unzip")[0]
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("link.txt").path)
        }
        check("zip a file named -m") {
            let dir = root.appendingPathComponent("zip-dash")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let files = ["-m", "a.txt", "b.txt"].map { dir.appendingPathComponent($0) }
            for f in files { try "x".write(to: f, atomically: true, encoding: .utf8) }
            let z = try action(files, "zip")[0]
            let listed = try Proc.run("/usr/bin/unzip", ["-Z1", z.path]).split(separator: "\n")
            return listed.contains("-m") && files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
        check("rename") {
            let copy = root.appendingPathComponent("tmp-a.txt")
            try "x".write(to: copy, atomically: true, encoding: .utf8)
            return try action([copy], "rename")[0].lastPathComponent == "renamed-1.txt"
        }
        // Second file missing: the first one's result must stay undoable. Undo is recorded on the main queue.
        let missing = root.appendingPathComponent("missing.png")
        check("batch failure keeps undo for done files") {
            do { _ = try action([png, missing], "to-jpg"); return false } catch {}
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let label = MainActor.assumeIsolated { UndoStore.label } ?? ""
            return label.hasPrefix("fixture ") && FileManager.default.fileExists(atPath: root.appendingPathComponent(label).path)
        }
        check("rename failure keeps undo for done files") {
            let b = root.appendingPathComponent("tmp-b.txt")
            try "x".write(to: b, atomically: true, encoding: .utf8)
            do { _ = try action([b, missing], "rename"); return false } catch {}
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard MainActor.assumeIsolated({ UndoStore.label }) == "rename" else { return false }
            MainActor.assumeIsolated { UndoStore.run() }
            return FileManager.default.fileExists(atPath: b.path)
        }

        check("pdf OCR") { try String(contentsOf: action([try action([words], "img-pdf")[0]], "pdf-ocr")[0], encoding: .utf8).contains("Orbit") }
        check("pdf lock + unlock") {
            let locked = try action([pdf], "lock")[0]
            guard PDFDocument(url: locked)?.isLocked == true else { return false }
            return PDFDocument(url: try action([locked], "unlock")[0])?.isEncrypted == false
        }
        check("pdf delete page") { PDFDocument(url: try action([pdf], "delpages")[0])?.pageCount == 1 }
        check("pdf extract page") { PDFDocument(url: try action([pdf], "extract")[0])?.pageCount == 1 }
        check("pdf watermark") { PDFDocument(url: try action([pdf], "watermark")[0])?.pageCount == 2 }

        // Editor renders (no windows): same code paths the Apply buttons use.
        check("frame render") {
            let img = try ImageEngine.load(png).0
            let out = FrameRender.render(img, backdrop: MainActor.assumeIsolated { FrameModel.backdrops[0] }, padding: 0.1, radius: 0.05, shadow: 0.5)
            return out.width == 480 && out.height == 380
        }
        check("redact black box") {
            let img = try ImageEngine.load(png).0
            // Canvas == pixels (k = 1); box over the top-left corner, which is white in the fixture.
            let out = MarkupRender.render(img, marks: [Mark(kind: .black, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 50, y: 50))], k: 1)
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(out.cropping(to: CGRect(x: 10, y: 10, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
            return p[0] < 10 && p[1] < 10 && p[2] < 10
        }
        check("crop model pixels") {
            MainActor.assumeIsolated {
                let m = CropModel(try! ImageEngine.load(png).0)
                m.setRatio(1)
                return m.pixelRect.width == 300 && m.pixelRect.height == 300
            }
        }
        check("metadata write") {
            let out = try Editors.writeMetadata(png, title: "T", author: "Test Author", note: "c", dropGPS: true, dropAll: false)
            let props = try ImageEngine.load(out).1
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let pngDict = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            return tiff?[kCGImagePropertyTIFFArtist] as? String == "Test Author" || pngDict?[kCGImagePropertyPNGAuthor] as? String == "Test Author"
        }

        check("ring stays on screen near the menu bar") {
            let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
            let f = RingController.frame(around: NSPoint(x: 1400, y: 898), size: NSSize(width: 480, height: 480), in: visible)
            return visible.contains(f) && f.minX == 960 && f.maxY == 875
        }
        // Hold-and-nudge trigger: the decision the drag watcher makes on each tick.
        check("ring trigger decisions") {
            let t0 = Date(), p0 = NSPoint(x: 500, y: 500)
            let step = DragWatcher.step
            return step(nil, p0, t0, false) == .start
                && step((p0, t0), NSPoint(x: 512, y: 506), t0.addingTimeInterval(0.1), false) == .wait
                && step((p0, t0), NSPoint(x: 512, y: 506), t0.addingTimeInterval(0.3), false) == .open
                && step((p0, t0), NSPoint(x: 700, y: 500), t0.addingTimeInterval(0.3), false) == .cancel
                && step((p0, t0), p0, t0.addingTimeInterval(0.05), true) == .open
        }
        // Editor gestures, driven through the same model calls the drag gestures make.
        check("crop drag: corner, ratio, move") {
            MainActor.assumeIsolated {
                let m = CropModel(try! ImageEngine.load(png).0)          // 400x300, k = 1
                m.drag(start: CGPoint(x: 400, y: 300), now: CGPoint(x: 200, y: 150)); m.endDrag()
                let free = m.rect == CGRect(x: 0, y: 0, width: 200, height: 150)
                m.setRatio(1)                                            // (50, 0, 300, 300)
                m.drag(start: CGPoint(x: 350, y: 300), now: CGPoint(x: 250, y: 200)); m.endDrag()
                let ratio = m.rect == CGRect(x: 50, y: 0, width: 200, height: 200)
                m.drag(start: CGPoint(x: 100, y: 100), now: CGPoint(x: 150, y: 100)); m.endDrag()
                return free && ratio && m.rect.minX == 100
            }
        }
        check("annotate drag draws a red arrow") {
            let (marks, k): ([Mark], CGFloat) = MainActor.assumeIsolated {
                let m = MarkupModel(try! ImageEngine.load(png).0, redact: false)
                m.drag(start: CGPoint(x: 20, y: 20), now: CGPoint(x: 60, y: 20))
                m.drag(start: CGPoint(x: 20, y: 20), now: CGPoint(x: 180, y: 20)); m.endDrag()
                return (m.marks, m.k)
            }
            guard marks.count == 1 else { return false }
            let out = MarkupRender.render(try ImageEngine.load(png).0, marks: marks, k: k)
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(out.cropping(to: CGRect(x: 100, y: 20, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 4)
            return p[0] > 200 && p[1] < 100 && p[2] < 100
        }

        if let ff = Media.ffmpegPath {
            // 2 s test clip: a 640x360 picture letterboxed inside 640x480.
            let mov = root.appendingPathComponent("clip.mp4")
            _ = try? Proc.run(ff, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=2",
                                   "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                                   "-vf", "pad=640:480:0:60:black", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", mov.path])
            check("video -> gif") { try action([mov], "to-gif")[0].pathExtension == "gif" }
            check("video -> mp3") { try action([mov], "v-mp3")[0].pathExtension == "mp3" }
            check("video auto crop") {
                let out = try action([mov], "autocrop")[0]
                return try Proc.run(ff, ["-hide_banner", "-i", out.path, "-frames:v", "1", "-f", "null", "-"]).contains("640x360")
            }
            check("audio normalize") {
                let wav = try action([mov], "v-wav")[0]
                return try action([wav], "norm")[0].pathExtension == "wav"
            }
            check("video trim") { (try MediaExtras.duration(action([mov], "vtrim")[0])) < 1.5 }
            check("contact sheet") { try action([mov], "sheet")[0].pathExtension == "jpg" }
            check("burn subtitles") {
                try "1\n00:00:00,000 --> 00:00:01,500\nHello\n".write(to: mov.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                return try action([mov], "subs")[0].pathExtension == "mp4"
            }
            check("burn subtitles, apostrophe in the name") {
                let named = root.appendingPathComponent("Don't stop.mp4")
                try? FileManager.default.removeItem(at: named)
                try FileManager.default.copyItem(at: mov, to: named)
                try "1\n00:00:00,000 --> 00:00:01,500\nHello\n".write(to: named.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                return try action([named], "subs")[0].pathExtension == "mp4"
            }
            // Same clip without an audio track, like a screen recording without a mic.
            let silent = root.appendingPathComponent("silent.mp4")
            _ = try? Proc.run(ff, ["-v", "error", "-y", "-i", mov.path, "-an", "-c:v", "copy", silent.path])
            check("2x speed without audio") { (try MediaExtras.duration(action([silent], "speed2")[0])) < 1.5 }
            check("failed ffmpeg run leaves no output") {
                do { _ = try Media.ffmpeg(silent, ext: "mp4", tag: "Broken", ["-filter_complex", "[0:a]atempo=2.0[a]", "-map", "[a]"]) } catch {
                    return !FileManager.default.fileExists(atPath: root.appendingPathComponent("silent Broken.mp4").path)
                }
                return false
            }
        } else {
            print("SKIP video/audio: ffmpeg not found")
        }

        print(failed == 0 ? "ALL PASSED (\(root.path))" : "\(failed) FAILED (\(root.path))")
        return failed == 0 ? 0 : 1
    }
}
