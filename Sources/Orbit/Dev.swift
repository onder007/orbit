import AppKit
import PDFKit
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
        } else {
            print("SKIP video/audio: ffmpeg not found")
        }

        print(failed == 0 ? "ALL PASSED (\(root.path))" : "\(failed) FAILED (\(root.path))")
        return failed == 0 ? 0 : 1
    }
}
