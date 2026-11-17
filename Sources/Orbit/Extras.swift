import AppKit
import CoreImage
import CoreText
import PDFKit
import Speech
import UniformTypeIdentifiers
import Vision

// MARK: - Vision: background removal, text recognition

enum VisionEngine {
    static func removeBackground(_ url: URL) throws -> URL {
        let img = try ImageEngine.load(url).0
        let handler = VNImageRequestHandler(cgImage: img)
        let req = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([req])
        guard let result = req.results?.first, !result.allInstances.isEmpty else { throw OrbitError("No subject found in this image") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ImageEngine.ci.createCGImage(ci, from: ci.extent) else { throw OrbitError("Background removal failed") }
        let out = outputURL(for: url, tag: "Cutout", ext: "png")
        try ImageEngine.write(cg, to: out, type: .png)
        return out
    }

    static func recognize(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["tr-TR", "en-US"]
        try VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Images: OCR. PDFs: the embedded text layer per page, OCR for pages without one (scans).
    static func ocr(_ url: URL) throws -> URL {
        var text: String
        if FileKind.of(url) == .pdf {
            let d = try PDFEngine.open(url)
            text = try (0..<d.pageCount).map { i -> String in
                let page = d.page(at: i)!
                if let s = page.string, s.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { return s }
                return try recognize(PDFEngine.render(page, scale: 2))
            }.joined(separator: "\n\n")
        } else {
            text = try recognize(ImageEngine.load(url).0)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OrbitError("No text found") }
        let out = outputURL(for: url, tag: "Text", ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

// MARK: - PDF: passwords, pages, watermark

enum PDFExtras {
    static func lock(_ url: URL) throws -> URL {
        let pw = try Ask.text("Lock PDF", "Password to open \(url.lastPathComponent):", secure: true)
        return try PDFEngine.save(try PDFEngine.open(url), like: url, tag: "Locked",
                                  options: [.userPasswordOption: pw, .ownerPasswordOption: pw])
    }

    static func unlock(_ url: URL) throws -> URL {
        guard let d = PDFDocument(url: url) else { throw OrbitError("Cannot read PDF") }
        guard d.isLocked || d.isEncrypted else { throw OrbitError("This PDF has no password") }
        if d.isLocked {
            let pw = try Ask.text("Unlock PDF", "Password for \(url.lastPathComponent):", secure: true)
            guard d.unlock(withPassword: pw) else { throw OrbitError("Wrong password") }
        }
        // Copy pages into a fresh document so no encryption carries over.
        let clean = PDFDocument()
        for i in 0..<d.pageCount { clean.insert(d.page(at: i)!.copy() as! PDFPage, at: i) }
        return try PDFEngine.save(clean, like: url, tag: "Unlocked")
    }

    static func deletePages(_ url: URL) throws -> URL {
        let d = try PDFEngine.open(url)
        let pages = try Ask.pages(Ask.text("Delete pages", "\(d.pageCount) pages. Which to delete?", placeholder: "e.g. 2, 5-7"), count: d.pageCount)
        guard pages.count < d.pageCount else { throw OrbitError("That would delete every page") }
        for i in pages.reversed() { d.removePage(at: i) }
        return try PDFEngine.save(d, like: url, tag: "Edited")
    }

    static func extractPages(_ url: URL) throws -> URL {
        let d = try PDFEngine.open(url)
        let pages = try Ask.pages(Ask.text("Extract pages", "\(d.pageCount) pages. Which to keep in a new PDF?", placeholder: "e.g. 1, 3-4"), count: d.pageCount)
        let out = PDFDocument()
        for i in pages { out.insert(d.page(at: i)!.copy() as! PDFPage, at: out.pageCount) }
        return try PDFEngine.save(out, like: url, tag: "Pages")
    }

    /// Draws each page, then a large diagonal text at low opacity on top.
    static func watermark(_ url: URL) throws -> URL {
        let text = try Ask.text("Watermark", "Text to stamp across every page:", placeholder: "CONFIDENTIAL")
        let d = try PDFEngine.open(url)
        let out = outputURL(for: url, tag: "Watermarked", ext: "pdf")
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw OrbitError("Could not create PDF") }
        for i in 0..<d.pageCount {
            let page = d.page(at: i)!
            var box = page.bounds(for: .mediaBox)
            ctx.beginPage(mediaBox: &box)
            page.draw(with: .mediaBox, to: ctx)
            let size = min(box.width, box.height) / CGFloat(max(text.count, 6)) * 1.6
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor(white: 0.5, alpha: 0.18),
            ]))
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.saveGState()
            ctx.translateBy(x: box.midX, y: box.midY)
            ctx.rotate(by: atan2(box.height, box.width))
            ctx.textPosition = CGPoint(x: -w / 2, y: -size / 3)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()
        return out
    }
}

// MARK: - Video & audio extras

enum MediaExtras {
    static var ffprobe: String? {
        Media.ffmpegPath.map { ($0 as NSString).deletingLastPathComponent + "/ffprobe" }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    static func duration(_ url: URL) throws -> Double {
        guard Media.ffmpegPath != nil else { throw Media.ffmpegMissing }
        guard let fp = ffprobe else { throw OrbitError("ffprobe was not found next to ffmpeg.") }
        let out = try Proc.run(fp, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        guard let d = Double(out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "") else {
            throw OrbitError("Could not read the duration")
        }
        return d
    }

    /// Asks for "start-end" (seconds or mm:ss) and cuts with a re-encode, so the cut is frame accurate.
    static func trim(_ url: URL, video: Bool) throws -> URL {
        let spec = try Ask.text("Trim", "Keep from - to (seconds or mm:ss):", placeholder: "0:05-0:20")
        let parts = spec.split(separator: "-").map(String.init)
        guard parts.count == 2, let a = Ask.seconds(parts[0]), let b = Ask.seconds(parts[1]), b > a else {
            throw OrbitError("Use the form 0:05-0:20")
        }
        let range = ["-ss", String(a), "-to", String(b)]
        return video
            ? try Media.ffmpeg(url, ext: "mp4", tag: "Trimmed", range + Media.h264)
            : try Media.ffmpeg(url, ext: url.pathExtension, tag: "Trimmed", range)
    }

    /// 4x4 grid of evenly spaced frames.
    static func contactSheet(_ url: URL) throws -> URL {
        let fps = 16 / max(try duration(url), 1)
        return try Media.ffmpeg(url, ext: "jpg", tag: "Sheet",
                                ["-vf", "fps=\(fps),scale=480:-2,tile=4x4:padding=6:margin=6:color=white", "-frames:v", "1", "-q:v", "3"])
    }

    /// Burns "name.srt" (next to the video) into the picture.
    static func burnSubtitles(_ url: URL) throws -> URL {
        let srt = url.deletingPathExtension().appendingPathExtension("srt")
        guard FileManager.default.fileExists(atPath: srt.path) else {
            throw OrbitError("Put \(srt.lastPathComponent) next to the video first")
        }
        // The filter argument breaks on some names (an apostrophe), so ffmpeg reads a copy with a plain name.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        try FileManager.default.copyItem(at: srt, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let escaped = tmp.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
        return try Media.video(url, tag: "Subtitled", vf: "subtitles='\(escaped)'")
    }

    /// On-device speech recognition; video goes through a temporary WAV first.
    static func transcribe(_ url: URL) throws -> URL {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            SFSpeechRecognizer.requestAuthorization { status = $0; sem.signal() }
            sem.wait()
        }
        guard status == .authorized else { throw OrbitError("Allow Speech Recognition for Orbit in System Settings") }
        var audio = url
        var tmp: URL?
        if FileKind.of(url) == .video, let ff = Media.ffmpegPath {
            let t = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try Proc.run(ff, ["-v", "error", "-y", "-i", url.path, "-vn", "-ac", "1", "-ar", "16000", t.path])
            audio = t; tmp = t
        }
        defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }

        // The file's language is unknown: try the system language and English, keep the more confident result.
        var ids = [Locale.current.identifier.replacingOccurrences(of: "_", with: "-"), "en-US", "tr-TR"]
        ids = ids.enumerated().filter { ids.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        var best: (text: String, confidence: Double)?
        var lastError: Error?
        for id in ids.prefix(2) {
            do {
                let r = try recognizeSpeech(audio, locale: Locale(identifier: id))
                if r.confidence > (best?.confidence ?? -1) { best = r }
            } catch { lastError = error }
        }
        guard let text = best?.text, !text.isEmpty else { throw lastError ?? OrbitError("No speech found") }
        let out = outputURL(for: url, tag: "Transcript", ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// One recognition pass; confidence is the mean over the transcription's segments.
    static func recognizeSpeech(_ audio: URL, locale: Locale) throws -> (text: String, confidence: Double) {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { throw OrbitError("Speech recognition is not available") }
        let req = SFSpeechURLRecognitionRequest(url: audio)
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.shouldReportPartialResults = false
        let sem = DispatchSemaphore(value: 0)
        var result: SFSpeechRecognitionResult?, failure: Error?
        let task = rec.recognitionTask(with: req) { r, error in
            if let r, r.isFinal { result = r; sem.signal() } else if let error { failure = error; sem.signal() }
        }
        if sem.wait(timeout: .now() + 1800) == .timedOut { task.cancel(); throw OrbitError("Transcription timed out") }
        guard let result else { throw OrbitError(failure?.localizedDescription ?? "No speech found") }
        let segs = result.bestTranscription.segments
        let conf = segs.isEmpty ? 0 : segs.map { Double($0.confidence) }.reduce(0, +) / Double(segs.count)
        return (result.bestTranscription.formattedString, conf)
    }
}

// MARK: - Icons

enum IconEngine {
    /// Square, centered crop at the given size.
    static func square(_ img: CGImage, _ side: Int) throws -> CGImage {
        let s = min(img.width, img.height)
        guard let c = img.cropping(to: CGRect(x: (img.width - s) / 2, y: (img.height - s) / 2, width: s, height: s)) else {
            throw OrbitError("Crop failed")
        }
        return try ImageEngine.scaled(c, to: CGSize(width: side, height: side))
    }

    static func icns(_ url: URL) throws -> URL {
        let img = try ImageEngine.load(url).0
        let set = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: set) }
        for base in [16, 32, 128, 256, 512] {
            try ImageEngine.write(square(img, base), to: set.appendingPathComponent("icon_\(base)x\(base).png"), type: .png)
            try ImageEngine.write(square(img, base * 2), to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"), type: .png)
        }
        let out = outputURL(for: url, tag: nil, ext: "icns")
        try Proc.run("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", out.path])
        return out
    }

    /// A folder with favicon.ico (32 px), favicon-16/32, apple-touch-icon (180) and 192/512 PNGs.
    static func favicons(_ url: URL) throws -> URL {
        let img = try ImageEngine.load(url).0
        let dir = outputURL(for: url, tag: "Favicons", ext: "")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes = [("favicon-16x16.png", 16), ("favicon-32x32.png", 32), ("apple-touch-icon.png", 180),
                     ("android-chrome-192x192.png", 192), ("android-chrome-512x512.png", 512)]
        for (name, side) in sizes { try ImageEngine.write(square(img, side), to: dir.appendingPathComponent(name), type: .png) }
        try ImageEngine.write(square(img, 32), to: dir.appendingPathComponent("favicon.ico"), type: UTType("com.microsoft.ico")!)
        return dir
    }
}

// MARK: - Files: zip, rename, palette, QR

enum FileOps {
    static func zip(_ urls: [URL]) throws -> URL {
        let dir = urls[0].deletingLastPathComponent()
        let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
        let out = outputURL(for: dir.appendingPathComponent(base), tag: nil, ext: "zip")
        // "--" so a file named like an option ("-m") is stored, not read as one.
        try Proc.run("/usr/bin/zip", ["-r", "-q", "-X", out.path, "--"] + urls.map(\.lastPathComponent), cwd: dir)
        return out
    }

    static func unzip(_ url: URL) throws -> URL {
        let out = outputURL(for: url, tag: nil, ext: "")
        try Proc.run("/usr/bin/ditto", ["-x", "-k", url.path, out.path])
        return out
    }

    /// "{name}", "{n}" and "{date}" in the pattern; renames in place and records undo.
    static func rename(_ urls: [URL]) throws -> [URL] {
        let pattern = try Ask.text("Rename \(urls.count) file\(urls.count == 1 ? "" : "s")",
                                   "Use {name}, {n} (1, 2, 3...) and {date}.", placeholder: "photo-{n}")
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let width = String(urls.count).count
        var pairs: [(URL, URL)] = []
        for (i, u) in urls.enumerated() {
            let n = String(repeating: "0", count: max(0, width - String(i + 1).count)) + String(i + 1)
            let name = pattern.replacingOccurrences(of: "{name}", with: u.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{n}", with: n).replacingOccurrences(of: "{date}", with: date)
                .replacingOccurrences(of: "/", with: "-")
            var target = u.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(u.pathExtension)
            if target != u, FileManager.default.fileExists(atPath: target.path) { target = outputURL(for: target, tag: nil, ext: u.pathExtension) }
            if target != u { try FileManager.default.moveItem(at: u, to: target) }
            pairs.append((u, target))
        }
        let moves = pairs
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                UndoStore.record("rename") {
                    for (from, to) in moves.reversed() where from != to { try? FileManager.default.moveItem(at: to, to: from) }
                }
            }
        }
        return pairs.map(\.1)
    }

    /// k-means on a 64x64 thumbnail; writes a swatch PNG and a text file with hex values.
    static func palette(_ url: URL) throws -> [URL] {
        let thumb = try ImageEngine.scaled(ImageEngine.load(url).0, to: CGSize(width: 64, height: 64))
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
        let px: [SIMD3<Double>] = (0..<64 * 64).map { SIMD3(Double(p[$0 * 4]), Double(p[$0 * 4 + 1]), Double(p[$0 * 4 + 2])) }
        func dist(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { let d = a - b; return (d * d).sum() }
        let k = 6
        var centers = (0..<k).map { px[$0 * px.count / k] }
        for _ in 0..<12 {
            var sums = [SIMD3<Double>](repeating: .zero, count: k), counts = [Int](repeating: 0, count: k)
            for v in px {
                let j = (0..<k).min { dist(v, centers[$0]) < dist(v, centers[$1]) }!
                sums[j] += v; counts[j] += 1
            }
            for j in 0..<k where counts[j] > 0 { centers[j] = sums[j] / Double(counts[j]) }
        }
        let hex = centers.map { String(format: "#%02X%02X%02X", Int($0.x), Int($0.y), Int($0.z)) }
        let sw = CGContext(data: nil, width: 120 * k, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        sw.setFillColor(.white); sw.fill(CGRect(x: 0, y: 0, width: 120 * k, height: 160))
        for (j, c) in centers.enumerated() {
            sw.setFillColor(CGColor(srgbRed: c.x / 255, green: c.y / 255, blue: c.z / 255, alpha: 1))
            sw.fill(CGRect(x: j * 120, y: 40, width: 120, height: 120))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: hex[j], attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.black]))
            sw.textPosition = CGPoint(x: CGFloat(j * 120 + 18), y: 14)
            CTLineDraw(line, sw)
        }
        let png = outputURL(for: url, tag: "Palette", ext: "png")
        try ImageEngine.write(sw.makeImage()!, to: png, type: .png)
        let txt = outputURL(for: url, tag: "Palette", ext: "txt")
        try (hex.joined(separator: "\n") + "\n").write(to: txt, atomically: true, encoding: .utf8)
        return [png, txt]
    }

    /// QR code for a text, URL or .webloc file's content.
    static func qr(_ url: URL) throws -> URL {
        let content: String
        if url.pathExtension.lowercased() == "webloc",
           let plist = NSDictionary(contentsOf: url), let link = plist["URL"] as? String {
            content = link
        } else {
            content = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !content.isEmpty, content.utf8.count <= 2000 else { throw OrbitError("Text must be 1-2000 bytes for a QR code") }
        let f = CIFilter(name: "CIQRCodeGenerator")!
        f.setValue(Data(content.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        let big = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 20, y: 20))
        guard let cg = ImageEngine.ci.createCGImage(big, from: big.extent) else { throw OrbitError("QR failed") }
        let out = outputURL(for: url, tag: "QR", ext: "png")
        try ImageEngine.write(cg, to: out, type: .png)
        return out
    }
}
