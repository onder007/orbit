import AppKit
import SwiftUI

/// Ring geometry, in points. Angles are degrees clockwise from 12 o'clock.
enum Ring {
    static let size: CGFloat = 480
    static let hub: CGFloat = 60
    static let inner: ClosedRange<CGFloat> = 68...132
    static let outer: ClosedRange<CGFloat> = 140...222
    static let gap: CGFloat = 5

    static func point(_ deg: Double, _ r: CGFloat, center c: CGPoint) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
    }
}

@MainActor
final class RingModel: ObservableObject {
    enum Status: Equatable { case idle, working(String), done(Int), failed(String) }

    let files: [URL]
    let segments: [Segment]
    @Published var activeSegment = 0
    @Published var hoverSegment: Int?
    @Published var hoverAction: Int?
    @Published var status = Status.idle
    var onFinish: (([URL]) -> Void)?

    init(files: [URL]) {
        self.files = files
        self.segments = Catalog.segments(for: files)
    }

    var segmentSpan: Double { 360 / Double(max(segments.count, 1)) }
    func segmentCenter(_ i: Int) -> Double { Double(i) * segmentSpan }

    /// Outer petals fan out around the active segment's direction.
    func actionAngles() -> [(start: Double, end: Double)] {
        guard segments.indices.contains(activeSegment) else { return [] }
        let n = segments[activeSegment].actions.count
        let step = min(38, 330 / Double(max(n, 1)))
        let first = segmentCenter(activeSegment) - step * Double(n) / 2
        return (0..<n).map { (first + step * Double($0), first + step * Double($0 + 1)) }
    }

    func hit(_ p: CGPoint, in size: CGSize) {
        guard status == .idle else { return }
        let dx = p.x - size.width / 2, dy = p.y - size.height / 2
        let r = (dx * dx + dy * dy).squareRoot()
        var deg = atan2(Double(dx), Double(-dy)) * 180 / .pi
        if deg < 0 { deg += 360 }

        if r > Ring.hub && r < Ring.inner.upperBound {
            let i = Int(((deg + segmentSpan / 2).truncatingRemainder(dividingBy: 360)) / segmentSpan) % max(segments.count, 1)
            hoverSegment = i; hoverAction = nil
            if activeSegment != i { withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { activeSegment = i } }
        } else if r >= Ring.inner.upperBound && r <= Ring.outer.upperBound + 20 {
            hoverSegment = nil
            hoverAction = actionAngles().firstIndex { a in
                let d = (deg - a.start).truncatingRemainder(dividingBy: 360)
                return (d < 0 ? d + 360 : d) < a.end - a.start
            }
        } else {
            hoverSegment = nil; hoverAction = nil
        }
    }

    var hoveredAction: Action? {
        guard let i = hoverAction, segments.indices.contains(activeSegment) else { return nil }
        let a = segments[activeSegment].actions
        return a.indices.contains(i) ? a[i] : nil
    }

    func fire() {
        guard status == .idle, let action = hoveredAction else { return }
        status = .working(action.title)
        let files = files
        Task.detached(priority: .userInitiated) {
            do {
                let out = try action.run(files)
                await MainActor.run { self.status = .done(out.count); self.onFinish?(out) }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription); self.onFinish?([]) }
            }
        }
    }
}

struct Petal: Shape {
    var start: Double, end: Double, r0: CGFloat, r1: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Shrink by the gap on every side; the round-join stroke in PetalView adds the corner radius back.
        let inset = Ring.gap / 2 + 5
        let a0 = r0 + inset, a1 = r1 - inset
        let da0 = Double(inset / a0) * 180 / .pi, da1 = Double(inset / a1) * 180 / .pi
        var p = Path()
        p.addArc(center: c, radius: a1, startAngle: .degrees(start + da1 - 90), endAngle: .degrees(end - da1 - 90), clockwise: false)
        p.addArc(center: c, radius: a0, startAngle: .degrees(end - da0 - 90), endAngle: .degrees(start + da0 - 90), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct PetalView: View {
    let petal: Petal
    let alpha: Double
    var body: some View {
        // Opaque fill + round-join stroke, then one opacity for the group: no doubled edge.
        petal.fill(.white).overlay(petal.stroke(.white, style: StrokeStyle(lineWidth: 10, lineJoin: .round)))
            .compositingGroup()
            .opacity(alpha)
    }
}

struct PetalLabel: View {
    let title: String, symbol: String, highlighted: Bool, compact: Bool
    var body: some View {
        VStack(spacing: compact ? 3 : 5) {
            Image(systemName: symbol).font(.system(size: compact ? 12 : 14, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: compact ? 9 : 9.5, weight: .bold, design: .rounded))
                .tracking(0.6)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(highlighted ? Color.black.opacity(0.88) : Color.white.opacity(0.9))
        .frame(width: compact ? 62 : 70)
    }
}

struct RingView: View {
    @ObservedObject var model: RingModel

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                // Outer action petals for the active segment.
                ForEach(Array(model.actionAngles().enumerated()), id: \.offset) { i, a in
                    let hot = model.hoverAction == i
                    let action = model.segments[model.activeSegment].actions[i]
                    PetalView(petal: Petal(start: a.start, end: a.end, r0: Ring.outer.lowerBound, r1: Ring.outer.upperBound),
                              alpha: hot ? 1 : 0.13)
                        .scaleEffect(hot ? 1.03 : 1)
                    PetalLabel(title: action.title, symbol: action.symbol, highlighted: hot, compact: true)
                        .position(Ring.point((a.start + a.end) / 2, (Ring.outer.lowerBound + Ring.outer.upperBound) / 2, center: c))
                }

                // Inner segment petals.
                ForEach(Array(model.segments.enumerated()), id: \.element.id) { i, s in
                    let mid = model.segmentCenter(i)
                    let active = model.activeSegment == i
                    PetalView(petal: Petal(start: mid - model.segmentSpan / 2, end: mid + model.segmentSpan / 2,
                                           r0: Ring.inner.lowerBound, r1: Ring.inner.upperBound),
                              alpha: active ? 0.30 : 0.09)
                    PetalLabel(title: s.title, symbol: s.symbol, highlighted: false, compact: false)
                        .opacity(active ? 1 : 0.75)
                        .position(Ring.point(mid, (Ring.inner.lowerBound + Ring.inner.upperBound) / 2, center: c))
                }

                Hub(model: model).position(c)
            }
            .contentShape(Circle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { model.hit(p, in: geo.size) }
            }
            .onTapGesture(coordinateSpace: .local) { p in model.hit(p, in: geo.size); model.fire() }
        }
        .frame(width: Ring.size, height: Ring.size)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.hoverAction)
    }
}

struct Hub: View {
    @ObservedObject var model: RingModel

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.55))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            content.padding(10)
        }
        .frame(width: Ring.hub * 2 - 6, height: Ring.hub * 2 - 6)
    }

    @ViewBuilder var content: some View {
        switch model.status {
        case .working(let title):
            VStack(spacing: 6) { ProgressView().controlSize(.small).tint(.white); caption(title) }
        case .done(let n):
            VStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 22, weight: .semibold))
                caption(n == 1 ? "Saved" : "\(n) files")
            }.foregroundStyle(.white)
        case .failed(let msg):
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 18))
                caption(msg).lineLimit(3)
            }.foregroundStyle(.white)
        case .idle:
            if let a = model.hoveredAction {
                VStack(spacing: 2) {
                    Text(a.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    caption(model.segments[model.activeSegment].title)
                }.foregroundStyle(.white)
            } else {
                VStack(spacing: 4) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: model.files.first?.path ?? "/"))
                        .resizable().frame(width: 34, height: 34)
                    caption(model.files.count == 1 ? sizeText : "\(model.files.count) files")
                }
            }
        }
    }

    var sizeText: String {
        let bytes = model.files.first.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .lineLimit(1).minimumScaleFactor(0.7)
    }
}
