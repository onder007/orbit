import AppKit
import CoreImage
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct OrbitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// New file next to `src`; never overwrites: "photo Resized.jpg", "photo Resized 2.jpg", ...
func outputURL(for src: URL, tag: String?, ext: String) -> URL {
    let dir = src.deletingLastPathComponent()
    let base = src.deletingPathExtension().lastPathComponent + (tag.map { " \($0)" } ?? "")
    var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
        n += 1
    }
    return url
}

// MARK: - Images (ImageIO + Core Image)

enum ImageEngine {
    static let ci = CIContext(options: [.useSoftwareRenderer: false])

    static func load(_ url: URL) throws -> (CGImage, [CFString: Any]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw OrbitError("Cannot read image \(url.lastPathComponent)") }
        var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        // Bake EXIF orientation in so every later step works on upright pixels.
        if let o = props[kCGImagePropertyOrientation] as? UInt32, o != 1 {
            let upright = CIImage(cgImage: img).oriented(forExifOrientation: Int32(o))
            if let cg = ci.createCGImage(upright, from: upright.extent) {
                props[kCGImagePropertyOrientation] = 1
                return (cg, props)
            }
        }
        return (img, props)
    }

    static func write(_ img: CGImage, to url: URL, type: UTType, quality: Double = 0.9, metadata: [CFString: Any]? = nil) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw OrbitError("\(type.preferredFilenameExtension ?? "This format") cannot be written on this Mac") }
        var opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let metadata {
            for k in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
                      kCGImagePropertyIPTCDictionary, kCGImagePropertyPNGDictionary] {
                if let v = metadata[k] { opts[k] = v }
            }
        }
        CGImageDestinationAddImage(dst, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw OrbitError("Could not write \(url.lastPathComponent)") }
    }

    static func flattened(_ img: CGImage, background: CGColor = .white) -> CGImage {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(background); ctx.fill(r); ctx.draw(img, in: r)
        return ctx.makeImage()!
    }

    static func convert(_ url: URL, to type: UTType) throws -> URL {
        let ext = type.preferredFilenameExtension ?? "img"
        if ext == "webp" { return try Media.ffmpeg(url, ext: "webp", tag: nil, ["-c:v", "libwebp", "-quality", "88"]) }
        let (img, meta) = try load(url)
        let out = outputURL(for: url, tag: nil, ext: ext)
        try write(["jpeg", "bmp"].contains(ext) ? flattened(img) : img, to: out, type: type, metadata: meta)
        return out
    }

    /// Writes in the source's own format (PNG for formats ImageIO cannot write back).
    static func rewrite(_ url: URL, tag: String, quality: Double = 0.92, keepMetadata: Bool = true, _ f: (CGImage) throws -> CGImage) throws -> URL {
        let (img, meta) = try load(url)
        var type = UTType(filenameExtension: url.pathExtension) ?? .png
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        if !writable.contains(type.identifier) { type = .png }
        let out = outputURL(for: url, tag: tag, ext: type.preferredFilenameExtension ?? "png")
        try write(try f(img), to: out, type: type, quality: quality, metadata: keepMetadata ? meta : nil)
        return out
    }

    static func scaled(_ img: CGImage, to size: CGSize) throws -> CGImage {
        let sx = size.width / CGFloat(img.width), sy = size.height / CGFloat(img.height)
        let f = CIFilter(name: "CILanczosScaleTransform")!
        f.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey)
        f.setValue(sy, forKey: kCIInputScaleKey)
        f.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
        let out = f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: size.width.rounded(), height: size.height.rounded()))
        guard let cg = ci.createCGImage(out, from: out.extent) else { throw OrbitError("Resize failed") }
        return cg
    }

    static func scale(_ url: URL, factor: CGFloat) throws -> URL {
        try rewrite(url, tag: "\(Int(factor * 100))%") { img in
            try scaled(img, to: CGSize(width: max(1, CGFloat(img.width) * factor), height: max(1, CGFloat(img.height) * factor)))
        }
    }

    static func fit(_ url: URL, longSide: CGFloat) throws -> URL {
        try rewrite(url, tag: "\(Int(longSide))px") { img in
            let k = longSide / CGFloat(max(img.width, img.height))
            return try scaled(img, to: CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k))
        }
    }

    /// Scales to cover the target box and center-crops the overflow.
    static func fill(_ url: URL, size: CGSize, tag: String) throws -> URL {
        try rewrite(url, tag: tag) { img in
            let k = max(size.width / CGFloat(img.width), size.height / CGFloat(img.height))
            let big = try scaled(img, to: CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k))
            let r = CGRect(x: (CGFloat(big.width) - size.width) / 2, y: (CGFloat(big.height) - size.height) / 2,
                           width: size.width, height: size.height).integral
            guard let c = big.cropping(to: r) else { throw OrbitError("Crop failed") }
            return c
        }
    }

    static func filter(_ url: URL, tag: String, _ f: @escaping (CIImage) -> CIImage) throws -> URL {
        try rewrite(url, tag: tag) { img in
            let out = f(CIImage(cgImage: img))
            guard let cg = ci.createCGImage(out, from: out.extent) else { throw OrbitError("\(tag) failed") }
            return cg
        }
    }

    static func autoEnhance(_ i: CIImage) -> CIImage {
        i.autoAdjustmentFilters(options: [.redEye: false]).reduce(i) { acc, f in
            f.setValue(acc, forKey: kCIInputImageKey); return f.outputImage ?? acc
        }
    }

    /// Crops away uniform borders (same color as the top-left pixel, small tolerance).
    static func trimBorders(_ img: CGImage) throws -> CGImage {
        let w = img.width, h = img.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let r0 = Int(p[0]), g0 = Int(p[1]), b0 = Int(p[2]), a0 = Int(p[3])
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let d = abs(Int(p[i]) - r0) + abs(Int(p[i + 1]) - g0) + abs(Int(p[i + 2]) - b0) + abs(Int(p[i + 3]) - a0)
                if d > 24 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX else { return img }
        // Bitmap rows run top-down in memory, which matches CGImage.cropping coordinates.
        return img.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) ?? img
    }

    /// Lowers JPEG quality until the file is under `bytes` (or quality reaches 0.3).
    static func shrink(_ url: URL, under bytes: Int) throws -> URL {
        let flat = flattened(try load(url).0)
        let out = outputURL(for: url, tag: "Small", ext: "jpg")
        var q = 0.85
        repeat {
            try write(flat, to: out, type: .jpeg, quality: q)
            if ((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= bytes { break }
            q -= 0.1
        } while q > 0.3
        return out
    }

    static func toPDF(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for u in urls {
            let img = try load(u).0
            if let page = PDFPage(image: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        let out = outputURL(for: urls[0], tag: urls.count > 1 ? "Combined" : nil, ext: "pdf")
        guard doc.write(to: out) else { throw OrbitError("Could not write PDF") }
        return out
    }
}

// MARK: - PDF (PDFKit)

enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: url) else { throw OrbitError("Cannot read PDF \(url.lastPathComponent)") }
        if d.isLocked { throw OrbitError("\(url.lastPathComponent) is password protected") }
        return d
    }

    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()!
    }

    static func toImages(_ url: URL, type: UTType, scale: CGFloat = 2) throws -> [URL] {
        let d = try open(url)
        return try (0..<d.pageCount).map { i in
            let out = outputURL(for: url, tag: d.pageCount > 1 ? "p\(i + 1)" : nil, ext: type.preferredFilenameExtension!)
            try ImageEngine.write(render(d.page(at: i)!, scale: scale), to: out, type: type)
            return out
        }
    }

    static func text(_ url: URL) throws -> String { try open(url).string ?? "" }

    static func save(_ d: PDFDocument, like url: URL, tag: String, options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
        let out = outputURL(for: url, tag: tag, ext: "pdf")
        guard d.write(to: out, withOptions: options) else { throw OrbitError("Could not write PDF") }
        return out
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let all = PDFDocument()
        for u in urls {
            let d = try open(u)
            for i in 0..<d.pageCount { all.insert(d.page(at: i)!.copy() as! PDFPage, at: all.pageCount) }
        }
        return try save(all, like: urls[0], tag: "Merged")
    }

    static func split(_ url: URL) throws -> [URL] {
        let d = try open(url)
        return try (0..<d.pageCount).map { i in
            let one = PDFDocument()
            one.insert(d.page(at: i)!.copy() as! PDFPage, at: 0)
            return try save(one, like: url, tag: "p\(i + 1)")
        }
    }

    static func transform(_ url: URL, tag: String, _ f: (PDFDocument) -> Void) throws -> URL {
        let d = try open(url); f(d); return try save(d, like: url, tag: tag)
    }

    static func compress(_ url: URL) throws -> URL {
        try save(try open(url), like: url, tag: "Compressed",
                 options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let d = try open(url); d.documentAttributes = [:]
        return try save(d, like: url, tag: "Clean")
    }
}

// MARK: - Documents (textutil + Core Text)

enum DocEngine {
    static func convert(_ url: URL, to ext: String) throws -> URL {
        if url.pathExtension.lowercased() == "pdf" {
            // PDF -> plain text first, then let textutil produce the target.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
            try PDFEngine.text(url).write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let out = outputURL(for: url, tag: nil, ext: ext)
            if ext == "txt" { try FileManager.default.copyItem(at: tmp, to: out); return out }
            try Proc.run("/usr/bin/textutil", ["-convert", ext, "-output", out.path, tmp.path])
            return out
        }
        if ext == "pdf" { return try toPDF(url) }
        let out = outputURL(for: url, tag: nil, ext: ext)
        try Proc.run("/usr/bin/textutil", ["-convert", ext, "-output", out.path, url.path])
        return out
    }

    /// Lays the document out on A4 pages with Core Text; safe off the main thread.
    static func toPDF(_ url: URL) throws -> URL {
        let text: NSAttributedString
        if ["txt", "md", "csv", "json"].contains(url.pathExtension.lowercased()) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            text = NSAttributedString(string: raw, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)])
        } else {
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
        let out = outputURL(for: url, tag: nil, ext: "pdf")
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(out as CFURL, mediaBox: &page, nil) else { throw OrbitError("Could not create PDF") }
        let setter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var pos = 0
        repeat {
            ctx.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: pos, length: 0),
                                                 CGPath(rect: page.insetBy(dx: 56, dy: 64), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let r = CTFrameGetVisibleStringRange(frame)
            if r.length == 0 { break }
            pos += r.length
        } while pos < text.length
        ctx.closePDF()
        return out
    }
}

// MARK: - Video & audio (ffmpeg)

enum Proc {
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let err = Pipe(), out = Pipe()
        p.standardError = err; p.standardOutput = out
        try p.run()
        // Drain stderr on another thread so a chatty process cannot fill the pipe and stall.
        var errData = Data()
        let reader = Thread { errData = err.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        while !reader.isFinished { usleep(1000) }
        let errText = String(decoding: errData, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw OrbitError(String(errText.split(separator: "\n").suffix(2).joined(separator: " ").prefix(300)))
        }
        return String(decoding: outData, as: UTF8.self) + errText
    }
}

enum Media {
    static let ffmpegPath: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func ffmpeg(_ url: URL, ext: String, tag: String?, _ args: [String]) throws -> URL {
        guard let ff = ffmpegPath else { throw OrbitError("ffmpeg is needed for video and audio. Install it and try again.") }
        let out = outputURL(for: url, tag: tag, ext: ext)
        do {
            try Proc.run(ff, ["-v", "error", "-y", "-i", url.path] + args + [out.path])
        } catch {
            // A failed run can leave an empty output behind.
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    static let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                       "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]

    static func video(_ url: URL, tag: String, vf: String) throws -> URL {
        try ffmpeg(url, ext: "mp4", tag: tag, ["-vf", vf] + h264)
    }

    static func gif(_ url: URL) throws -> URL {
        try ffmpeg(url, ext: "gif", tag: nil,
                   ["-vf", "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                    "-loop", "0"])
    }

    /// Two passes: cropdetect finds the black bars, then crop with the most common value.
    static func autoCrop(_ url: URL) throws -> URL {
        guard let ff = ffmpegPath else { throw OrbitError("ffmpeg is needed for video") }
        let log = try Proc.run(ff, ["-hide_banner", "-i", url.path, "-vf", "cropdetect=limit=24:round=2:reset=0",
                                    "-frames:v", "240", "-an", "-f", "null", "-"])
        let crops = log.components(separatedBy: "crop=").dropFirst()
            .compactMap { $0.split(whereSeparator: { $0 == "\n" || $0 == " " }).first.map(String.init) }
        guard let crop = Dictionary(grouping: crops, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key
        else { throw OrbitError("No black bars found") }
        return try video(url, tag: "Cropped", vf: "crop=\(crop)")
    }
}
