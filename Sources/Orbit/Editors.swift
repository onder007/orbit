import AppKit
import CoreImage
import CoreText
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// Editor windows for actions that need a hand on the image: crop, frame, annotate, redact, metadata.
// State lives in ObservableObject models: @State needs the SwiftUI macro plugin, which ships only with Xcode.

// MARK: - Window plumbing

private final class WindowCloser: NSObject, NSWindowDelegate {
    var onClose: () -> Void = {}
    func windowWillClose(_ n: Notification) { onClose() }
}

enum Editor {
    /// Shows the view in a window and blocks the calling (background) thread until Apply or close.
    static func show(title: String, _ make: @MainActor (_ finish: @escaping (Bool) -> Void) -> AnyView) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var applied = false
        var closer: WindowCloser?
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                RingController.shared.hideForPrompt()
                let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                w.title = title
                w.titlebarAppearsTransparent = true
                w.isReleasedWhenClosed = false
                w.appearance = NSAppearance(named: .aqua)
                w.backgroundColor = NSColor(red: 1, green: 0.973, blue: 0.95, alpha: 1)
                w.level = .floating
                var done = false
                let finish: (Bool) -> Void = { ok in
                    guard !done else { return }
                    done = true
                    applied = ok
                    w.orderOut(nil)
                    sem.signal()
                }
                let c = WindowCloser()
                c.onClose = { finish(false) }
                w.delegate = c
                closer = c
                let host = NSHostingView(rootView: make(finish))
                w.contentView = host
                w.setContentSize(host.fittingSize)
                w.center()
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        }
        sem.wait()
        _ = closer
        return applied
    }

    /// Fits the image into the editor's canvas; `k` converts canvas points to image pixels.
    static func fit(_ img: CGImage, max: CGSize = CGSize(width: 560, height: 440)) -> (size: CGSize, k: CGFloat) {
        let s = min(max.width / CGFloat(img.width), max.height / CGFloat(img.height), 1)
        return (CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s), 1 / s)
    }
}

// MARK: - Shared controls

struct Chip: View {
    let title: String, selected: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Palette.ink.opacity(0.75))
                .background(Capsule().fill(selected ? Palette.accent : Color.white.opacity(0.85)))
                .overlay(Capsule().strokeBorder(Color.black.opacity(selected ? 0 : 0.06)))
        }.buttonStyle(.plain)
    }
}

struct EditorButtons: View {
    let reset: (() -> Void)?
    let apply: () -> Void
    var resetTitle = "Reset"
    var applyTitle = "Apply"
    var body: some View {
        HStack {
            if let reset {
                Button(action: reset) {
                    Text(resetTitle).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(Palette.ink.opacity(0.7))
                        .background(Capsule().fill(Color.black.opacity(0.06)))
                }.buttonStyle(.plain)
            }
            Spacer()
            Button(action: apply) {
                Text(applyTitle).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(LinearGradient(colors: [Palette.accent, Palette.accentDeep], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: Palette.accentDeep.opacity(0.3), radius: 6, y: 2)
            }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.ink.opacity(0.65))
                .frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).tint(Palette.accent)
        }
    }
}

func editorCard<V: View>(_ v: V) -> some View {
    v.padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 20).frame(minWidth: 600)
}

// MARK: - Crop

@MainActor
final class CropModel: ObservableObject {
    let image: CGImage
    let size: CGSize
    let k: CGFloat
    @Published var rect: CGRect
    @Published var ratio: CGFloat?
    private var mode: Int?          // 0-3 corner, 4 move, 5 new selection
    private var startRect = CGRect.zero

    init(_ img: CGImage) {
        image = img
        (size, k) = Editor.fit(img)
        rect = CGRect(origin: .zero, size: size)
    }

    static let ratios: [(String, CGFloat?)] = [("Free", nil), ("1:1", 1), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4)]

    func setRatio(_ r: CGFloat?) {
        ratio = r
        guard let r else { return }
        // Largest centered rect with that ratio.
        var w = size.width, h = w / r
        if h > size.height { h = size.height; w = h * r }
        rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    func reset() { ratio = nil; rect = CGRect(origin: .zero, size: size) }

    var corners: [CGPoint] { Self.corners(rect) }
    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    func drag(start: CGPoint, now: CGPoint) {
        if mode == nil {
            startRect = rect
            if let c = corners.firstIndex(where: { hypot($0.x - start.x, $0.y - start.y) < 16 }) { mode = c }
            else if rect.contains(start) { mode = 4 }
            else { mode = 5 }
        }
        let bounds = CGRect(origin: .zero, size: size)
        let clamp = { (p: CGPoint) in CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY)) }
        if mode == 4 {
            var r = startRect.offsetBy(dx: now.x - start.x, dy: now.y - start.y)
            r.origin.x = min(max(r.minX, 0), size.width - r.width)
            r.origin.y = min(max(r.minY, 0), size.height - r.height)
            rect = r
            return
        }
        let anchor = mode == 5 ? clamp(start) : Self.corners(startRect)[(mode! + 2) % 4]
        let p = clamp(now)
        var w = abs(p.x - anchor.x), h = abs(p.y - anchor.y)
        if let r = ratio { if w / max(h, 1) > r { w = h * r } else { h = w / r } }
        w = max(w, 12); h = max(h, 12)
        rect = CGRect(x: p.x < anchor.x ? anchor.x - w : anchor.x, y: p.y < anchor.y ? anchor.y - h : anchor.y,
                      width: w, height: h).intersection(bounds)
    }
    func endDrag() { mode = nil }

    var pixelRect: CGRect {
        CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}

struct CropView: View {
    @ObservedObject var m: CropModel
    let finish: (Bool) -> Void

    var body: some View {
        editorCard(VStack(spacing: 16) {
            ZStack(alignment: .topLeading) {
                Image(decorative: m.image, scale: 1).resizable().frame(width: m.size.width, height: m.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                // Dim everything outside the crop.
                Path { p in p.addRect(CGRect(origin: .zero, size: m.size)); p.addRect(m.rect) }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                Path(m.rect).stroke(Palette.accent, lineWidth: 2)
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(Palette.accent).overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: 13, height: 13).position(m.corners[i])
                }
            }
            .frame(width: m.size.width, height: m.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { m.drag(start: $0.startLocation, now: $0.location) }
                .onEnded { _ in m.endDrag() })

            HStack(spacing: 6) {
                Text("Aspect ratio").font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.ink.opacity(0.6))
                Spacer().frame(width: 6)
                ForEach(CropModel.ratios, id: \.0) { title, r in Chip(title: title, selected: m.ratio == r) { m.setRatio(r) } }
                Spacer()
                Text("\(Int(m.pixelRect.width)) × \(Int(m.pixelRect.height)) px")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.6))
            }
            EditorButtons(reset: { m.reset() }, apply: { finish(true) })
        })
    }
}

// MARK: - Frame (add background)

struct Backdrop: Identifiable {
    let id: Int
    let colors: [Color]
    let cg: [CGColor]
}

@MainActor
final class FrameModel: ObservableObject {
    let image: CGImage
    let size: CGSize
    @Published var backdrop = 0
    @Published var padding = 0.10
    @Published var radius = 0.03
    @Published var shadow = 0.5

    static let backdrops: [Backdrop] = {
        let sets: [[(Double, Double, Double)]] = [
            [(1, 0.42, 0.29), (0.98, 0.70, 0.35)], [(0.96, 0.33, 0.45), (0.62, 0.52, 0.85)], [(0.25, 0.55, 0.95), (0.45, 0.85, 0.85)],
            [(0.18, 0.70, 0.55), (0.70, 0.90, 0.50)], [(0.12, 0.12, 0.14), (0.30, 0.30, 0.34)], [(0.97, 0.95, 0.92), (0.90, 0.87, 0.82)],
            [(1, 1, 1), (1, 1, 1)], [(0.05, 0.05, 0.06), (0.05, 0.05, 0.06)],
        ]
        return sets.enumerated().map { i, s in
            Backdrop(id: i, colors: s.map { Color(red: $0.0, green: $0.1, blue: $0.2) },
                     cg: s.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) })
        }
    }()

    init(_ img: CGImage) { image = img; size = Editor.fit(img, max: CGSize(width: 420, height: 320)).size }
    func reset() { backdrop = 0; padding = 0.10; radius = 0.03; shadow = 0.5 }
}

struct FrameView: View {
    @ObservedObject var m: FrameModel
    let finish: (Bool) -> Void

    var body: some View {
        let pad = m.padding * Double(max(m.size.width, m.size.height))
        let r = m.radius * Double(min(m.size.width, m.size.height))
        let b = FrameModel.backdrops[m.backdrop]
        return editorCard(VStack(spacing: 16) {
            ZStack {
                LinearGradient(colors: b.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(decorative: m.image, scale: 1).resizable().frame(width: m.size.width, height: m.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                    .shadow(color: .black.opacity(0.35 * m.shadow), radius: 22 * m.shadow, y: 10 * m.shadow)
            }
            .frame(width: m.size.width + 2 * pad, height: m.size.height + 2 * pad)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(height: 440)

            HStack(spacing: 8) {
                ForEach(FrameModel.backdrops) { bd in
                    Button { m.backdrop = bd.id } label: {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(LinearGradient(colors: bd.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(m.backdrop == bd.id ? Palette.accent : Color.black.opacity(0.08), lineWidth: m.backdrop == bd.id ? 2.5 : 1))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            LabeledSlider(title: "Padding", value: Binding(get: { m.padding }, set: { m.padding = $0 }), range: 0...0.3)
            LabeledSlider(title: "Corners", value: Binding(get: { m.radius }, set: { m.radius = $0 }), range: 0...0.15)
            LabeledSlider(title: "Shadow", value: Binding(get: { m.shadow }, set: { m.shadow = $0 }), range: 0...1)
            EditorButtons(reset: { m.reset() }, apply: { finish(true) })
        })
    }
}

enum FrameRender {
    /// Full-resolution version of FrameView's preview.
    static func render(_ img: CGImage, backdrop: Backdrop, padding: Double, radius: Double, shadow: Double) -> CGImage {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let pad = CGFloat(padding) * max(w, h), r = CGFloat(radius) * min(w, h)
        let W = Int(w + 2 * pad), H = Int(h + 2 * pad)
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: backdrop.cg as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: CGFloat(W), y: 0), options: [])
        let box = CGRect(x: pad, y: pad, width: w, height: h)
        let path = CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
        if shadow > 0 {
            ctx.saveGState()
            let scale = max(w, h) / 420
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * shadow * scale), blur: 44 * shadow * scale,
                          color: CGColor(gray: 0, alpha: 0.35 * shadow))
            ctx.addPath(path); ctx.setFillColor(.black); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.addPath(path); ctx.clip()
        ctx.draw(img, in: box)
        return ctx.makeImage()!
    }
}

// MARK: - Markup (annotate and redact)

struct Mark: Identifiable {
    enum Kind { case arrow, box, text, black, blur, pixel }
    let id = UUID()
    var kind: Kind
    var a: CGPoint
    var b: CGPoint
    var color: Color = .red
    var cg = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    var text = ""
    var rect: CGRect { CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
}

@MainActor
final class MarkupModel: ObservableObject {
    let image: CGImage
    let size: CGSize
    let k: CGFloat
    let tools: [(String, Mark.Kind)]
    @Published var tool: Mark.Kind
    @Published var marks: [Mark] = []
    @Published var color = 0
    @Published var text = "Note"
    private var live: Int?

    static let colors: [(Color, CGColor)] = [
        (1, 0.23, 0.19), (1, 0.58, 0), (1, 0.8, 0), (0.2, 0.78, 0.35), (0, 0.48, 1), (0.1, 0.1, 0.1), (1, 1, 1),
    ].map { (Color(red: $0.0, green: $0.1, blue: $0.2), CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1)) }

    init(_ img: CGImage, redact: Bool) {
        image = img
        (size, k) = Editor.fit(img)
        tools = redact ? [("Black", .black), ("Blur", .blur), ("Pixelate", .pixel)] : [("Arrow", .arrow), ("Box", .box), ("Text", .text)]
        tool = tools[0].1
    }

    func drag(start: CGPoint, now: CGPoint) {
        if live == nil {
            var mk = Mark(kind: tool, a: start, b: now)
            (mk.color, mk.cg) = Self.colors[color]
            mk.text = text
            marks.append(mk)
            live = marks.count - 1
        }
        marks[live!].b = now
    }
    func endDrag() { live = nil }
    func undo() { if !marks.isEmpty { marks.removeLast() } }
}

struct ArrowPath: Shape {
    let a: CGPoint, b: CGPoint
    var head: CGFloat = 16
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: a); p.addLine(to: b)
        let ang = atan2(b.y - a.y, b.x - a.x)
        for d in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            p.move(to: b); p.addLine(to: CGPoint(x: b.x + head * cos(ang + d), y: b.y + head * sin(ang + d)))
        }
        return p
    }
}

struct MarkShape: View {
    let m: Mark
    var body: some View {
        switch m.kind {
        case .arrow:
            ArrowPath(a: m.a, b: m.b).stroke(m.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        case .box:
            Path(roundedRect: m.rect, cornerRadius: 4).stroke(m.color, lineWidth: 3.5)
        case .text:
            Text(m.text).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(m.color)
                .shadow(color: .black.opacity(0.25), radius: 2).position(m.b)
        case .black:
            Path(m.rect).fill(Color.black)
        case .blur, .pixel:
            Path(m.rect).fill(Color.white.opacity(0.55))
                .overlay(Path(m.rect).stroke(Palette.ink.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4])))
        }
    }
}

struct MarkupView: View {
    @ObservedObject var m: MarkupModel
    let finish: (Bool) -> Void
    var redact: Bool { m.tools.first?.1 == .black }

    var body: some View {
        editorCard(VStack(spacing: 16) {
            ZStack(alignment: .topLeading) {
                Image(decorative: m.image, scale: 1).resizable().frame(width: m.size.width, height: m.size.height)
                ForEach(m.marks) { MarkShape(m: $0) }
            }
            .frame(width: m.size.width, height: m.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { m.drag(start: $0.startLocation, now: $0.location) }
                .onEnded { _ in m.endDrag() })

            HStack(spacing: 6) {
                ForEach(m.tools, id: \.0) { title, kind in Chip(title: title, selected: m.tool == kind) { m.tool = kind } }
                if !redact {
                    Spacer().frame(width: 8)
                    ForEach(0..<MarkupModel.colors.count, id: \.self) { i in
                        Button { m.color = i } label: {
                            Circle().fill(MarkupModel.colors[i].0).frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(m.color == i ? Palette.accent : Color.black.opacity(0.15), lineWidth: m.color == i ? 2.5 : 1))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                if m.tool == .text {
                    TextField("Text", text: Binding(get: { m.text }, set: { m.text = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 140)
                }
            }
            EditorButtons(reset: { m.undo() }, apply: { finish(true) }, resetTitle: "Undo", applyTitle: "Save")
        })
    }
}

enum MarkupRender {
    /// Draws marks (in canvas points, top-left origin) onto the full-resolution image.
    static func render(_ img: CGImage, marks: [Mark], k: CGFloat) -> CGImage {
        let W = img.width, H = img.height
        var base = CIImage(cgImage: img)
        // Blur / pixelate: filter the whole image once per mark, composite through the mark's rect.
        for mk in marks where mk.kind == .blur || mk.kind == .pixel {
            let r = CGRect(x: mk.rect.minX * k, y: CGFloat(H) - mk.rect.maxY * k, width: mk.rect.width * k, height: mk.rect.height * k)
            let amount = CGFloat(max(W, H)) / 60
            let filtered = mk.kind == .blur
                ? base.clampedToExtent().applyingGaussianBlur(sigma: Double(amount))
                : base.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(amount, 8), kCIInputCenterKey: CIVector(x: 0, y: 0)])
            base = filtered.cropped(to: r).composited(over: base)
        }
        let flat = ImageEngine.ci.createCGImage(base, from: CGRect(x: 0, y: 0, width: W, height: H))!
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(flat, in: CGRect(x: 0, y: 0, width: W, height: H))
        // Flip once so marks draw in canvas coordinates.
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: k, y: -k)
        for mk in marks {
            ctx.setStrokeColor(mk.cg)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            switch mk.kind {
            case .arrow:
                ctx.setLineWidth(4)
                ctx.addPath(ArrowPath(a: mk.a, b: mk.b).path(in: .zero).cgPath); ctx.strokePath()
            case .box:
                ctx.setLineWidth(3.5)
                ctx.addPath(CGPath(roundedRect: mk.rect, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.strokePath()
            case .black:
                ctx.setFillColor(.black); ctx.fill(mk.rect)
            case .text:
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: mk.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor(cgColor: mk.cg) ?? .red]))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.saveGState()
                // Undo the flip around the text so it reads upright.
                ctx.translateBy(x: mk.b.x - w / 2, y: mk.b.y + 8); ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            case .blur, .pixel:
                break
            }
        }
        return ctx.makeImage()!
    }
}

// MARK: - Metadata

@MainActor
final class MetaModel: ObservableObject {
    let url: URL
    let isPDF: Bool
    let rows: [(String, String)]
    @Published var title: String
    @Published var author: String
    @Published var note: String
    @Published var dropGPS = false
    @Published var dropAll = false

    init(_ url: URL) throws {
        self.url = url
        isPDF = FileKind.of(url) == .pdf
        if isPDF {
            let attrs = try PDFEngine.open(url).documentAttributes ?? [:]
            rows = attrs.map { ("\($0.key)", "\($0.value)") }.sorted { $0.0 < $1.0 }
            title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
            author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""
            note = attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        } else {
            let props = try ImageEngine.load(url).1
            var flat: [(String, String)] = []
            for (k, v) in props {
                let group = "\(k)".trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                if let d = v as? [CFString: Any] { for (k2, v2) in d { flat.append(("\(group) · \(k2)", "\(v2)")) } }
                else { flat.append((group, "\(v)")) }
            }
            rows = flat.sorted { $0.0 < $1.0 }
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            title = tiff[kCGImagePropertyTIFFImageDescription] as? String ?? ""
            author = tiff[kCGImagePropertyTIFFArtist] as? String ?? ""
            note = tiff[kCGImagePropertyTIFFCopyright] as? String ?? ""
        }
    }
}

struct MetaView: View {
    @ObservedObject var m: MetaModel
    let finish: (Bool) -> Void

    func field(_ label: String, _ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Palette.ink.opacity(0.65))
                .frame(width: 74, alignment: .leading)
            TextField(label, text: Binding(get: get, set: set)).textFieldStyle(.roundedBorder)
        }
    }

    var body: some View {
        editorCard(VStack(alignment: .leading, spacing: 12) {
            Text(m.url.lastPathComponent).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(m.rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top) {
                            Text(row.0).foregroundStyle(Palette.ink.opacity(0.55)).frame(width: 200, alignment: .leading)
                            Text(row.1).foregroundStyle(Palette.ink.opacity(0.85)).textSelection(.enabled)
                            Spacer()
                        }.font(.system(size: 11, design: .monospaced))
                    }
                    if m.rows.isEmpty { Text("No metadata").foregroundStyle(Palette.ink.opacity(0.5)) }
                }.padding(12)
            }
            .frame(height: 230)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.8)))
            field("Title", { m.title }, { m.title = $0 })
            field("Author", { m.author }, { m.author = $0 })
            field(m.isPDF ? "Subject" : "Copyright", { m.note }, { m.note = $0 })
            HStack(spacing: 18) {
                if !m.isPDF { Toggle("Remove location", isOn: Binding(get: { m.dropGPS }, set: { m.dropGPS = $0 })) }
                Toggle("Remove everything else", isOn: Binding(get: { m.dropAll }, set: { m.dropAll = $0 }))
            }.toggleStyle(.checkbox).font(.system(size: 12, design: .rounded))
            EditorButtons(reset: nil, apply: { finish(true) }, applyTitle: "Save Copy")
        })
    }
}

// MARK: - Actions

enum Editors {
    static func crop(_ url: URL) throws -> URL {
        let img = try ImageEngine.load(url).0
        var model: CropModel!
        guard Editor.show(title: "Crop Image", { finish in
            model = CropModel(img); return AnyView(CropView(m: model, finish: finish))
        }) else { throw OrbitError("Cancelled") }
        let r = DispatchQueue.main.sync { MainActor.assumeIsolated { model.pixelRect } }
        return try ImageEngine.rewrite(url, tag: "Cropped") { img in
            guard let c = img.cropping(to: r) else { throw OrbitError("Crop failed") }
            return c
        }
    }

    static func frame(_ url: URL) throws -> URL {
        let img = try ImageEngine.load(url).0
        var model: FrameModel!
        guard Editor.show(title: "Add Background", { finish in
            model = FrameModel(img); return AnyView(FrameView(m: model, finish: finish))
        }) else { throw OrbitError("Cancelled") }
        let p = DispatchQueue.main.sync {
            MainActor.assumeIsolated { (FrameModel.backdrops[model.backdrop], model.padding, model.radius, model.shadow) }
        }
        let out = outputURL(for: url, tag: "Framed", ext: "png")
        try ImageEngine.write(FrameRender.render(img, backdrop: p.0, padding: p.1, radius: p.2, shadow: p.3), to: out, type: .png)
        return out
    }

    static func markup(_ url: URL, redact: Bool) throws -> URL {
        let img = try ImageEngine.load(url).0
        var model: MarkupModel!
        guard Editor.show(title: redact ? "Redact" : "Annotate", { finish in
            model = MarkupModel(img, redact: redact); return AnyView(MarkupView(m: model, finish: finish))
        }) else { throw OrbitError("Cancelled") }
        let (marks, k) = DispatchQueue.main.sync { MainActor.assumeIsolated { (model.marks, model.k) } }
        guard !marks.isEmpty else { throw OrbitError("Nothing was drawn") }
        // Redacted copies drop metadata too, so hidden details do not survive in EXIF.
        return try ImageEngine.rewrite(url, tag: redact ? "Redacted" : "Annotated", keepMetadata: !redact) {
            MarkupRender.render($0, marks: marks, k: k)
        }
    }

    static func metadata(_ url: URL) throws -> URL {
        let model: MetaModel = try DispatchQueue.main.sync { try MainActor.assumeIsolated { try MetaModel(url) } }
        guard Editor.show(title: "Metadata", { finish in AnyView(MetaView(m: model, finish: finish)) }) else { throw OrbitError("Cancelled") }
        let v = DispatchQueue.main.sync {
            MainActor.assumeIsolated { (model.title, model.author, model.note, model.dropGPS, model.dropAll) }
        }
        return try writeMetadata(url, title: v.0, author: v.1, note: v.2, dropGPS: v.3, dropAll: v.4)
    }

    /// Writes a copy with the edited fields. dropAll keeps only the three fields; dropGPS removes location.
    static func writeMetadata(_ url: URL, title: String, author: String, note: String, dropGPS: Bool, dropAll: Bool) throws -> URL {
        if FileKind.of(url) == .pdf {
            let d = try PDFEngine.open(url)
            var attrs: [AnyHashable: Any] = dropAll ? [:] : (d.documentAttributes ?? [:])
            attrs[PDFDocumentAttribute.titleAttribute] = title.isEmpty ? nil : title
            attrs[PDFDocumentAttribute.authorAttribute] = author.isEmpty ? nil : author
            attrs[PDFDocumentAttribute.subjectAttribute] = note.isEmpty ? nil : note
            d.documentAttributes = attrs
            return try PDFEngine.save(d, like: url, tag: "Meta")
        }
        let (img, original) = try ImageEngine.load(url)
        var props: [CFString: Any] = dropAll ? [:] : original
        if dropGPS { props[kCGImagePropertyGPSDictionary] = nil }
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFImageDescription] = title.isEmpty ? nil : title
        tiff[kCGImagePropertyTIFFArtist] = author.isEmpty ? nil : author
        tiff[kCGImagePropertyTIFFCopyright] = note.isEmpty ? nil : note
        props[kCGImagePropertyTIFFDictionary] = tiff
        // PNG keeps these in its own text chunks.
        var pngDict = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        pngDict[kCGImagePropertyPNGDescription] = title.isEmpty ? nil : title
        pngDict[kCGImagePropertyPNGAuthor] = author.isEmpty ? nil : author
        pngDict[kCGImagePropertyPNGCopyright] = note.isEmpty ? nil : note
        props[kCGImagePropertyPNGDictionary] = pngDict
        var type = UTType(filenameExtension: url.pathExtension) ?? .png
        if !((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(type.identifier) { type = .png }
        let out = outputURL(for: url, tag: "Meta", ext: type.preferredFilenameExtension ?? "png")
        try ImageEngine.write(img, to: out, type: type, quality: 0.95, metadata: props)
        return out
    }
}
