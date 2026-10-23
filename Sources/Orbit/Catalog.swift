import CoreImage
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum FileKind: String {
    case image, pdf, document, video, audio, archive, unknown

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        guard let t = UTType(filenameExtension: ext) else { return .unknown }
        if t.conforms(to: .pdf) { return .pdf }
        if ext == "zip" { return .archive }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .text) || t.conforms(to: .rtf) || ["doc", "docx", "odt", "md", "webarchive", "webloc"].contains(ext) { return .document }
        return .unknown
    }
}

struct Action: Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// Needs more than one file (merge, combine).
    var multi = false
    let run: ([URL]) throws -> [URL]
}

struct Segment: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let actions: [Action]
}

/// One output per input file, reporting progress after each.
private func each(_ f: @escaping (URL) throws -> URL) -> ([URL]) throws -> [URL] { eachMany { [try f($0)] } }
private func eachMany(_ f: @escaping (URL) throws -> [URL]) -> ([URL]) throws -> [URL] {
    { files in
        var out: [URL] = []
        for (i, u) in files.enumerated() { out += try f(u); RunProgress.report?(i + 1, files.count) }
        return out
    }
}
private func act(_ id: String, _ title: String, _ symbol: String, _ f: @escaping (URL) throws -> URL) -> Action {
    Action(id: id, title: title, symbol: symbol, run: each(f))
}

enum Catalog {
    static func segments(for files: [URL]) -> [Segment] {
        guard let first = files.first else { return [] }
        let all: [Segment]
        switch FileKind.of(first) {
        case .image: all = image
        case .pdf: all = pdf
        case .document: all = document
        case .video: all = video
        case .audio: all = audio
        case .archive: all = archive
        case .unknown: all = []
        }
        // Hide merge/combine for a single file, and the target format equal to the source.
        var ext = first.pathExtension.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        return all.map { s in
            Segment(id: s.id, title: s.title, symbol: s.symbol,
                    actions: s.actions.filter { (files.count > 1 || !$0.multi) && $0.id != "to-\(ext)" })
        }.filter { !$0.actions.isEmpty } + [file]
    }

    /// Shown for every kind of file.
    static let file = Segment(id: "file", title: "File", symbol: "folder", actions: [
        Action(id: "zip", title: "ZIP", symbol: "doc.zipper") { [try FileOps.zip($0)] },
        Action(id: "rename", title: "Rename", symbol: "character.cursor.ibeam", run: FileOps.rename),
    ])

    static let archive: [Segment] = [
        Segment(id: "archive", title: "Archive", symbol: "archivebox", actions: [act("unzip", "Unzip", "arrow.up.bin", FileOps.unzip)]),
    ]

    // MARK: Image

    static let image: [Segment] = [
        Segment(id: "convert", title: "Convert", symbol: "arrow.triangle.2.circlepath", actions:
            [("png", UTType.png), ("jpg", .jpeg), ("heic", .heic), ("webp", UTType(filenameExtension: "webp")!),
             ("tiff", .tiff), ("gif", .gif), ("bmp", .bmp)]
                .map { ext, t in act("to-\(ext)", ext.uppercased(), "photo") { try ImageEngine.convert($0, to: t) } }
            + [Action(id: "img-pdf", title: "PDF", symbol: "doc.richtext") { [try ImageEngine.toPDF($0)] }]),

        Segment(id: "resize", title: "Resize", symbol: "arrow.up.left.and.arrow.down.right", actions: [
            act("s25", "25%", "minus.magnifyingglass") { try ImageEngine.scale($0, factor: 0.25) },
            act("s50", "50%", "minus.magnifyingglass") { try ImageEngine.scale($0, factor: 0.5) },
            act("s200", "2x", "plus.magnifyingglass") { try ImageEngine.scale($0, factor: 2) },
            act("w1080", "1080 px", "ruler") { try ImageEngine.fit($0, longSide: 1080) },
            act("w2048", "2048 px", "ruler") { try ImageEngine.fit($0, longSide: 2048) },
            act("sq", "1:1", "square") { try ImageEngine.fill($0, size: CGSize(width: 1080, height: 1080), tag: "1x1") },
            act("portrait", "4:5", "rectangle.portrait") { try ImageEngine.fill($0, size: CGSize(width: 1080, height: 1350), tag: "4x5") },
            act("story", "9:16", "iphone") { try ImageEngine.fill($0, size: CGSize(width: 1080, height: 1920), tag: "9x16") },
            act("wide", "16:9", "rectangle") { try ImageEngine.fill($0, size: CGSize(width: 1920, height: 1080), tag: "16x9") },
        ]),

        Segment(id: "edit", title: "Edit", symbol: "slider.horizontal.3", actions: [
            act("crop", "Crop", "crop", Editors.crop),
            act("rotl", "Rotate L", "rotate.left") { try ImageEngine.filter($0, tag: "Rotated") { $0.oriented(.left) } },
            act("rotr", "Rotate R", "rotate.right") { try ImageEngine.filter($0, tag: "Rotated") { $0.oriented(.right) } },
            act("flip", "Flip", "arrow.left.and.right") { try ImageEngine.filter($0, tag: "Flipped") { $0.oriented(.upMirrored) } },
            act("trim", "Trim", "crop") { try ImageEngine.rewrite($0, tag: "Trimmed", ImageEngine.trimBorders) },
            act("enhance", "Enhance", "wand.and.stars") { try ImageEngine.filter($0, tag: "Enhanced", ImageEngine.autoEnhance) },
            act("mono", "Mono", "circle.lefthalf.filled") { try ImageEngine.filter($0, tag: "Mono") { $0.applyingFilter("CIPhotoEffectNoir") } },
            act("sharpen", "Sharpen", "diamond") {
                try ImageEngine.filter($0, tag: "Sharp") { $0.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.6]) }
            },
        ]),

        Segment(id: "design", title: "Design", symbol: "paintpalette", actions: [
            act("frame", "Add BG", "photo.artframe", Editors.frame),
            act("annotate", "Annotate", "pencil.tip.crop.circle", { try Editors.markup($0, redact: false) }),
            act("redact", "Redact", "eye.slash.fill", { try Editors.markup($0, redact: true) }),
            act("cutout", "Remove BG", "person.crop.rectangle", VisionEngine.removeBackground),
            act("flatten", "Fill BG", "square.fill") { try ImageEngine.rewrite($0, tag: "Filled") { ImageEngine.flattened($0) } },
            Action(id: "palette", title: "Palette", symbol: "swatchpalette", run: eachMany(FileOps.palette)),
            act("icns", "Mac Icon", "app.dashed", IconEngine.icns),
            act("favicon", "Favicons", "globe", IconEngine.favicons),
        ]),

        Segment(id: "optimize", title: "Optimize", symbol: "gauge.with.dots.needle.33percent", actions: [
            act("compress", "Compress", "arrow.down.right.and.arrow.up.left") { try ImageEngine.rewrite($0, tag: "Compressed", quality: 0.7) { $0 } },
            act("under1", "< 1 MB", "scalemass") { try ImageEngine.shrink($0, under: 1_000_000) },
            act("under300", "< 300 KB", "scalemass") { try ImageEngine.shrink($0, under: 300_000) },
            act("strip", "No EXIF", "eye.slash") { try ImageEngine.rewrite($0, tag: "Clean", keepMetadata: false) { $0 } },
            act("ocr", "Copy Text", "text.viewfinder", VisionEngine.ocr),
            act("meta", "Metadata", "info.circle", Editors.metadata),
        ]),
    ]

    // MARK: PDF

    static let pdf: [Segment] = [
        Segment(id: "convert", title: "Convert", symbol: "arrow.triangle.2.circlepath", actions: [
            Action(id: "pdf-png", title: "PNG", symbol: "photo", run: eachMany { try PDFEngine.toImages($0, type: .png) }),
            Action(id: "pdf-jpg", title: "JPG", symbol: "photo", run: eachMany { try PDFEngine.toImages($0, type: .jpeg) }),
            act("pdf-txt", "TXT", "text.alignleft") { try DocEngine.convert($0, to: "txt") },
            act("pdf-docx", "DOCX", "doc.text") { try DocEngine.convert($0, to: "docx") },
            act("pdf-rtf", "RTF", "doc.text") { try DocEngine.convert($0, to: "rtf") },
            act("pdf-html", "HTML", "chevron.left.forwardslash.chevron.right") { try DocEngine.convert($0, to: "html") },
            act("pdf-ocr", "OCR", "text.viewfinder", VisionEngine.ocr),
        ]),
        Segment(id: "pages", title: "Pages", symbol: "doc.on.doc", actions: [
            Action(id: "merge", title: "Merge", symbol: "square.stack.3d.down.forward", multi: true) { [try PDFEngine.merge($0)] },
            Action(id: "split", title: "Split", symbol: "scissors", run: eachMany(PDFEngine.split)),
            act("rot", "Rotate", "rotate.right") { try PDFEngine.transform($0, tag: "Rotated") { d in
                for i in 0..<d.pageCount { d.page(at: i)!.rotation += 90 }
            } },
            act("rev", "Reverse", "arrow.up.arrow.down") { try PDFEngine.transform($0, tag: "Reversed") { d in
                for i in 0..<d.pageCount { let p = d.page(at: d.pageCount - 1)!; d.removePage(at: d.pageCount - 1); d.insert(p, at: i) }
            } },
            act("cover", "Cover", "photo.on.rectangle") { u in
                let d = try PDFEngine.open(u)
                let out = outputURL(for: u, tag: "Cover", ext: "png")
                try ImageEngine.write(PDFEngine.render(d.page(at: 0)!, scale: 2), to: out, type: .png)
                return out
            },
            act("delpages", "Delete", "trash", PDFExtras.deletePages),
            act("extract", "Extract", "doc.badge.plus", PDFExtras.extractPages),
        ]),
        Segment(id: "secure", title: "Secure", symbol: "lock", actions: [
            act("lock", "Lock", "lock.fill", PDFExtras.lock),
            act("unlock", "Unlock", "lock.open", PDFExtras.unlock),
            act("watermark", "Watermark", "seal", PDFExtras.watermark),
        ]),
        Segment(id: "optimize", title: "Optimize", symbol: "gauge.with.dots.needle.33percent", actions: [
            act("pdf-compress", "Compress", "arrow.down.right.and.arrow.up.left", PDFEngine.compress),
            act("pdf-clean", "No Meta", "eye.slash", PDFEngine.stripMetadata),
            act("pdf-meta", "Metadata", "info.circle", Editors.metadata),
        ]),
    ]

    // MARK: Documents

    static let document: [Segment] = [
        Segment(id: "convert", title: "Convert", symbol: "arrow.triangle.2.circlepath", actions:
            ["pdf", "docx", "rtf", "txt", "html", "odt", "doc"].map { ext in
                act("to-\(ext)", ext.uppercased(), ext == "pdf" ? "doc.richtext" : "doc.text") { try DocEngine.convert($0, to: ext) }
            }),
        Segment(id: "tools", title: "Tools", symbol: "wrench.and.screwdriver", actions: [act("qr", "QR Code", "qrcode", FileOps.qr)]),
    ]

    // MARK: Video

    static let video: [Segment] = [
        Segment(id: "convert", title: "Convert", symbol: "arrow.triangle.2.circlepath", actions: [
            act("to-mp4", "MP4", "film") { try Media.ffmpeg($0, ext: "mp4", tag: nil, Media.h264) },
            act("to-mov", "MOV", "film") { try Media.ffmpeg($0, ext: "mov", tag: nil, Media.h264) },
            act("to-webm", "WebM", "globe") { try Media.ffmpeg($0, ext: "webm", tag: nil, ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]) },
            act("to-gif", "GIF", "sparkles.tv", Media.gif),
            act("frame", "Frame", "photo") { try Media.ffmpeg($0, ext: "png", tag: "Frame", ["-frames:v", "1"]) },
        ]),
        Segment(id: "frame", title: "Frame", symbol: "crop", actions: [
            act("autocrop", "Auto Crop", "crop", Media.autoCrop),
            act("v916", "9:16", "iphone") { try Media.video($0, tag: "9x16", vf: "crop='min(iw,ih*9/16)':'min(ih,iw*16/9)',scale=1080:1920") },
            act("v11", "1:1", "square") { try Media.video($0, tag: "1x1", vf: "crop='min(iw,ih)':'min(iw,ih)',scale=1080:1080") },
            act("v720", "720p", "rectangle") { try Media.video($0, tag: "720p", vf: "scale=-2:720") },
            act("v1080", "1080p", "rectangle") { try Media.video($0, tag: "1080p", vf: "scale=-2:1080") },
            act("vrot", "Rotate", "rotate.right") { try Media.video($0, tag: "Rotated", vf: "transpose=1") },
            act("vtrim", "Trim", "timeline.selection") { try MediaExtras.trim($0, video: true) },
        ]),
        Segment(id: "audio", title: "Audio", symbol: "waveform", actions: [
            act("v-mp3", "MP3", "music.note") { try Media.ffmpeg($0, ext: "mp3", tag: nil, ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]) },
            act("v-wav", "WAV", "waveform") { try Media.ffmpeg($0, ext: "wav", tag: nil, ["-vn"]) },
            act("mute", "Mute", "speaker.slash") { try Media.ffmpeg($0, ext: $0.pathExtension, tag: "Muted", ["-an", "-c:v", "copy"]) },
            act("vtranscribe", "Transcribe", "captions.bubble", MediaExtras.transcribe),
            act("subs", "Subtitles", "captions.bubble.fill", MediaExtras.burnSubtitles),
        ]),
        Segment(id: "optimize", title: "Optimize", symbol: "gauge.with.dots.needle.33percent", actions: [
            act("vcompress", "Compress", "arrow.down.right.and.arrow.up.left") {
                try Media.ffmpeg($0, ext: "mp4", tag: "Compressed",
                                 ["-c:v", "libx264", "-preset", "slow", "-crf", "28", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"])
            },
            act("sheet", "Contact Sheet", "square.grid.3x3", MediaExtras.contactSheet),
            act("web", "Web Ready", "bolt") { try Media.ffmpeg($0, ext: "mp4", tag: "Web", ["-c", "copy", "-movflags", "+faststart"]) },
            act("speed2", "2x Speed", "forward") {
                try Media.ffmpeg($0, ext: "mp4", tag: "2x", ["-filter_complex", "[0:v]setpts=0.5*PTS[v];[0:a]atempo=2.0[a]", "-map", "[v]", "-map", "[a]"] + Media.h264)
            },
        ]),
    ]

    // MARK: Audio

    static let audio: [Segment] = [
        Segment(id: "convert", title: "Convert", symbol: "arrow.triangle.2.circlepath", actions:
            [("mp3", ["-c:a", "libmp3lame", "-q:a", "2"]), ("m4a", ["-c:a", "aac", "-b:a", "192k"]), ("wav", []),
             ("flac", ["-c:a", "flac"]), ("aiff", []), ("ogg", ["-c:a", "libvorbis", "-q:a", "6"])]
                .map { ext, args in act("to-\(ext)", ext.uppercased(), "music.note") { try Media.ffmpeg($0, ext: ext, tag: nil, ["-vn"] + args) } }),
        Segment(id: "edit", title: "Edit", symbol: "slider.horizontal.3", actions: [
            act("norm", "Normalize", "speaker.wave.2") { try Media.ffmpeg($0, ext: $0.pathExtension, tag: "Normalized", ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]) },
            act("trimsil", "Trim Silence", "scissors") {
                try Media.ffmpeg($0, ext: $0.pathExtension, tag: "Trimmed",
                                 ["-af", "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse"])
            },
            act("atrim", "Trim", "timeline.selection") { try MediaExtras.trim($0, video: false) },
            act("atranscribe", "Transcribe", "captions.bubble", MediaExtras.transcribe),
            act("monoa", "Mono", "circle.lefthalf.filled") { try Media.ffmpeg($0, ext: $0.pathExtension, tag: "Mono", ["-ac", "1"]) },
            act("fade", "Fade", "chart.line.downtrend.xyaxis") {
                try Media.ffmpeg($0, ext: $0.pathExtension, tag: "Faded", ["-af", "afade=t=in:d=1.5,areverse,afade=t=in:d=1.5,areverse"])
            },
        ]),
    ]
}
