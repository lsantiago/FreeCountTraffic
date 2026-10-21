import SwiftUI
import TrafficCore

/// A box (counting box or study area) in view points: centre, half sizes and clockwise rotation.
private struct ViewBox {
    var c: CGPoint
    var hw: CGFloat
    var hh: CGFloat
    var angle: CGFloat

    static func rotate(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat) -> CGPoint {
        CGPoint(x: x * cos(a) - y * sin(a), y: x * sin(a) + y * cos(a))
    }

    /// View point of a point given in the box's own frame.
    func world(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
        let r = Self.rotate(lx, ly, angle)
        return CGPoint(x: c.x + r.x, y: c.y + r.y)
    }

    /// A view point in the box's own frame.
    func local(_ p: CGPoint) -> CGPoint { Self.rotate(p.x - c.x, p.y - c.y, -angle) }

    func contains(_ p: CGPoint) -> Bool {
        let l = local(p)
        return abs(l.x) <= hw && abs(l.y) <= hh
    }

    /// The four corners with their sign in the box frame (top-left = -1, -1).
    var corners: [(sx: CGFloat, sy: CGFloat, p: CGPoint)] {
        let signs: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        return signs.map { (sx: $0.0, sy: $0.1, p: world($0.0 * hw, $0.1 * hh)) }
    }

    /// The rotation handle sits above the middle of the top edge.
    var rotateHandle: CGPoint { world(0, -hh - 28) }
}

/// Frame + live boxes + editable counting boxes, with zoom/pan and an optional study area.
/// Zone coordinates are normalized to the frame; everything is drawn and edited in view points.
struct FrameView: View {
    let frame: CGImage?
    let tracks: [Track]
    let trails: [Int: [CGPoint]]
    let fps: Double?
    let zones: [Zone]
    let counts: [Int: Int]
    let selectedId: Int?
    let studyArea: RectN?
    let onSelect: (Int) -> Void
    let onZoneChange: (Int, RectN, Float) -> Void
    let onStudyAreaChange: (RectN?) -> Void

    private enum Mode {
        case move
        case corner(sx: CGFloat, sy: CGFloat)
        case rotate
        case pan
    }

    private struct Active {
        var mode: Mode
        /// zone id (nil = study area)
        var zoneId: Int?
        var start: ViewBox
        var startPan: CGSize
    }

    @State private var active: Active?
    @State private var dragStarted = false
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var pinchStart: CGFloat?
    @State private var pinching = false
    @State private var editingArea = false

    private let handleRadius: CGFloat = 24
    private let minSide: CGFloat = 18
    private static let zoomSteps: [CGFloat] = [1, 1.5, 2, 3, 4]

    private var aspect: CGFloat {
        guard let f = frame, f.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(f.width) / CGFloat(f.height)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let c = content(size)
            ZStack(alignment: .topLeading) {
                Color.black
                if let frame {
                    Image(decorative: frame, scale: 1).resizable()
                        .frame(width: c.width, height: c.height)
                        .offset(x: c.minX, y: c.minY)
                }
                // drawn in view points (outside the zoom transform) so lines and labels stay sharp
                Canvas { ctx, s in draw(ctx, s) }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(drag(size))
            .simultaneousGesture(pinch(size))
            // double tap: 200% around the tapped point, again: back to the whole picture
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                setZoom(zoom > 1.01 ? 1 : 2, anchor: v.location, size)
            })
            .overlay(alignment: .topLeading) { toolbar(size) }
            .overlay(alignment: .topTrailing) { fpsBadge }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: overlays

    private func toolbar(_ size: CGSize) -> some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Self.zoomSteps, id: \.self) { z in
                    Button("\(Int(z * 100))%") { setZoom(z, anchor: CGPoint(x: size.width / 2, y: size.height / 2), size) }
                }
            } label: {
                Label("\(Int((zoom * 100).rounded()))%", systemImage: "plus.magnifyingglass")
            }
            Button {
                editingArea.toggle()
                if editingArea && studyArea == nil {
                    onStudyAreaChange(RectN(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9))
                }
            } label: {
                Label(editingArea ? "Done" : "Study area", systemImage: editingArea ? "checkmark" : "crop")
            }
            if editingArea, studyArea != nil {
                Button { onStudyAreaChange(nil); editingArea = false } label: {
                    Label("Whole frame", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .labelStyle(.titleAndIcon)
        .buttonStyle(.plain)
        .foregroundColor(.white)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.55), in: Capsule())
        .padding(8)
    }

    @ViewBuilder private var fpsBadge: some View {
        if let fps, fps > 0 {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.system(size: 11))
                Text("\(Int(fps.rounded())) FPS").font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(8)
        }
    }

    // MARK: coordinates (normalized frame <-> view points)

    /// The picture at 100%: as large as fits in the view.
    private func baseSize(_ v: CGSize) -> CGSize {
        let w = min(v.width, v.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }

    /// Keeps the zoomed picture covering the view (or centred along an axis where it is smaller than the view).
    private func clampOrigin(_ o: CGSize, _ d: CGSize, _ v: CGSize) -> CGSize {
        CGSize(width: d.width <= v.width ? (v.width - d.width) / 2 : min(0, max(v.width - d.width, o.width)),
               height: d.height <= v.height ? (v.height - d.height) / 2 : min(0, max(v.height - d.height, o.height)))
    }

    /// Where the picture is drawn in the view: zooming enlarges it over the whole view (like the reference app),
    /// not only inside its own letterboxed rectangle.
    private func content(_ v: CGSize) -> CGRect {
        let b = baseSize(v)
        let d = CGSize(width: b.width * zoom, height: b.height * zoom)
        let o = clampOrigin(pan, d, v)
        return CGRect(x: o.width, y: o.height, width: d.width, height: d.height)
    }

    private func toView(_ x: Float, _ y: Float, _ size: CGSize) -> CGPoint {
        let c = content(size)
        return CGPoint(x: CGFloat(x) * c.width + c.minX, y: CGFloat(y) * c.height + c.minY)
    }

    private func rect(_ r: RectN, _ size: CGSize) -> CGRect {
        let c = content(size)
        return CGRect(x: CGFloat(r.left) * c.width + c.minX, y: CGFloat(r.top) * c.height + c.minY,
                      width: CGFloat(r.width) * c.width, height: CGFloat(r.height) * c.height)
    }

    private func viewBox(_ r: RectN, angle: Float, _ size: CGSize) -> ViewBox {
        let v = rect(r, size)
        return ViewBox(c: CGPoint(x: v.midX, y: v.midY), hw: v.width / 2, hh: v.height / 2, angle: CGFloat(angle))
    }

    private func rectN(_ b: ViewBox, _ size: CGSize) -> RectN {
        let c = content(size)
        let sx = c.width, sy = c.height
        let cx = (b.c.x - c.minX) / sx, cy = (b.c.y - c.minY) / sy
        let w = b.hw / sx, h = b.hh / sy
        return RectN(left: Float(cx - w), top: Float(cy - h), right: Float(cx + w), bottom: Float(cy + h))
    }

    // MARK: drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        for t in tracks {
            let c = Theme.track(t.id)
            let r = rect(t.box, size)
            // trailing line = recent path of the vehicle's centre (what the counting rule uses)
            if let pts = trails[t.id], pts.count > 1 {
                var path = Path()
                path.move(to: toView(Float(pts[0].x), Float(pts[0].y), size))
                for p in pts.dropFirst() { path.addLine(to: toView(Float(p.x), Float(p.y), size)) }
                ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(c), lineWidth: 1.5)
            let tag = t.cls.label
            let tagRect = CGRect(x: r.minX, y: r.minY - 15, width: CGFloat(tag.count) * 6.4 + 10, height: 15)
            ctx.fill(Path(roundedRect: tagRect, cornerRadius: 2), with: .color(c.opacity(0.9)))
            ctx.draw(Text(tag).font(.system(size: 10, weight: .semibold)).foregroundColor(.white),
                     at: CGPoint(x: tagRect.minX + 5, y: tagRect.midY), anchor: .leading)
        }

        // outside the study area is dimmed: vehicles there are not analysed
        if let area = studyArea {
            let a = rect(area, size)
            var shade = Path(CGRect(origin: .zero, size: size))
            shade.addRect(a)
            ctx.fill(shade, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
            ctx.stroke(Path(a), with: .color(.white), style: StrokeStyle(lineWidth: editingArea ? 2 : 1, dash: [6, 4]))
        }

        for (i, z) in zones.enumerated() {
            let c = Theme.zone(i)
            let selected = z.id == selectedId && !editingArea
            let b = viewBox(z.rect, angle: z.rotation, size)
            let r = CGRect(x: -b.hw, y: -b.hh, width: 2 * b.hw, height: 2 * b.hh)

            var g = ctx
            g.translateBy(x: b.c.x, y: b.c.y)
            g.rotate(by: .radians(Double(b.angle)))
            let path = Path(roundedRect: r, cornerRadius: 6)
            g.fill(path, with: .color(c.opacity(selected ? 0.40 : 0.28)))
            g.stroke(path, with: .color(c), lineWidth: selected ? 3 : 2)

            // name and direction on a dark pill so vehicle labels passing underneath never hide them
            var title = z.name
            if let d = z.direction { title += "  " + d.arrow }
            let label = g.resolve(Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white))
            let ls = label.measure(in: CGSize(width: max(r.width - 8, 20), height: 20))
            let pill = CGRect(x: r.minX + 3, y: r.minY + 3, width: ls.width + 8, height: ls.height + 4)
            g.fill(Path(roundedRect: pill, cornerRadius: 4), with: .color(Color(white: 0.12, opacity: 0.75)))
            g.draw(label, in: pill.insetBy(dx: 4, dy: 2))

            // big count badge in the middle of the box, always upright (measured, so long counts fit)
            let count = ctx.resolve(Text("\(counts[z.id] ?? 0)").font(.system(size: 16, weight: .bold).monospacedDigit()).foregroundColor(.white))
            let cs = count.measure(in: size)
            let badge = CGRect(x: b.c.x - (cs.width + 16) / 2, y: b.c.y - 13, width: cs.width + 16, height: 26)
            ctx.fill(Path(roundedRect: badge, cornerRadius: 8), with: .color(Color(white: 0.12, opacity: 0.75)))
            ctx.draw(count, at: CGPoint(x: badge.midX, y: badge.midY))

            if selected { drawHandles(ctx, b, color: c, rotation: true) }
        }

        if editingArea, let area = studyArea {
            drawHandles(ctx, viewBox(area, angle: 0, size), color: .white, rotation: false)
        }
    }

    private func drawHandles(_ ctx: GraphicsContext, _ b: ViewBox, color: Color, rotation: Bool) {
        for corner in b.corners { dot(ctx, corner.p, color) }
        guard rotation else { return }
        let top = b.world(0, -b.hh)
        let h = b.rotateHandle
        var stem = Path()
        stem.move(to: top)
        stem.addLine(to: h)
        ctx.stroke(stem, with: .color(.white), lineWidth: 1.5)
        ctx.fill(Path(ellipseIn: CGRect(x: h.x - 12, y: h.y - 12, width: 24, height: 24)), with: .color(.white))
        var icon = ctx.resolve(Image(systemName: "arrow.clockwise"))
        icon.shading = .color(.black)
        ctx.draw(icon, in: CGRect(x: h.x - 7, y: h.y - 7, width: 14, height: 14))
    }

    private func dot(_ ctx: GraphicsContext, _ p: CGPoint, _ color: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(color))
    }

    // MARK: zoom

    private func clampPan(_ p: CGSize, _ size: CGSize) -> CGSize {
        let b = baseSize(size)
        return clampOrigin(p, CGSize(width: b.width * zoom, height: b.height * zoom), size)
    }

    /// Zooms keeping the picture point under `anchor` (view point) in place.
    private func setZoom(_ z: CGFloat, anchor: CGPoint, _ size: CGSize) {
        let next = min(max(z, 1), 4)
        let c = content(size)
        let qx = (anchor.x - c.minX) / c.width, qy = (anchor.y - c.minY) / c.height
        let b = baseSize(size)
        zoom = next
        pan = clampPan(CGSize(width: anchor.x - qx * b.width * next, height: anchor.y - qy * b.height * next), size)
    }

    private func pinch(_ size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = zoom; pinching = true; active = nil }
                setZoom((pinchStart ?? 1) * v, anchor: CGPoint(x: size.width / 2, y: size.height / 2), size)
            }
            .onEnded { _ in
                pinchStart = nil
                if !dragStarted { pinching = false }
            }
    }

    // MARK: editing gesture

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= handleRadius }

    /// What a touch starting at `p` grabs: handles of the selected box first, then any box (selected first),
    /// otherwise the picture itself (pan) when zoomed in.
    private func grab(_ p: CGPoint, _ size: CGSize) -> Active? {
        let origin = content(size).origin
        let pan = CGSize(width: origin.x, height: origin.y)
        if editingArea {
            guard let area = studyArea else { return nil }
            let b = viewBox(area, angle: 0, size)
            if let k = b.corners.first(where: { near($0.p, p) }) {
                return Active(mode: .corner(sx: k.sx, sy: k.sy), zoneId: nil, start: b, startPan: pan)
            }
            if b.contains(p) { return Active(mode: .move, zoneId: nil, start: b, startPan: pan) }
            return zoom > 1 ? Active(mode: .pan, zoneId: nil, start: b, startPan: pan) : nil
        }
        if let z = zones.first(where: { $0.id == selectedId }) {
            let b = viewBox(z.rect, angle: z.rotation, size)
            if near(b.rotateHandle, p) { return Active(mode: .rotate, zoneId: z.id, start: b, startPan: pan) }
            if let k = b.corners.first(where: { near($0.p, p) }) {
                return Active(mode: .corner(sx: k.sx, sy: k.sy), zoneId: z.id, start: b, startPan: pan)
            }
        }
        let ordered = zones.sorted { a, b in (a.id == selectedId ? 1 : 0) > (b.id == selectedId ? 1 : 0) }
        if let z = ordered.first(where: { viewBox($0.rect, angle: $0.rotation, size).contains(p) }) {
            onSelect(z.id)
            return Active(mode: .move, zoneId: z.id, start: viewBox(z.rect, angle: z.rotation, size), startPan: pan)
        }
        return zoom > 1 ? Active(mode: .pan, zoneId: nil, start: ViewBox(c: .zero, hw: 0, hh: 0, angle: 0), startPan: pan) : nil
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard size.width > 0, size.height > 0, !pinching else { return }
                if !dragStarted {
                    dragStarted = true
                    active = grab(v.startLocation, size)
                }
                guard let a = active else { return }
                let p = v.location
                var b = a.start
                switch a.mode {
                case .pan:
                    pan = clampPan(CGSize(width: a.startPan.width + v.translation.width,
                                          height: a.startPan.height + v.translation.height), size)
                    return
                case .move:
                    b.c = CGPoint(x: a.start.c.x + v.translation.width, y: a.start.c.y + v.translation.height)
                    // keep the centre on the picture
                    let c = content(size)
                    b.c.x = min(max(b.c.x, c.minX), c.maxX)
                    b.c.y = min(max(b.c.y, c.minY), c.maxY)
                case let .corner(sx, sy):
                    // the opposite corner stays where it is
                    let fixed = a.start.world(-sx * a.start.hw, -sy * a.start.hh)
                    let d = ViewBox.rotate(p.x - fixed.x, p.y - fixed.y, -a.start.angle)
                    let w = max(d.x * sx, minSide), h = max(d.y * sy, minSide)
                    let off = ViewBox.rotate(sx * w / 2, sy * h / 2, a.start.angle)
                    b.c = CGPoint(x: fixed.x + off.x, y: fixed.y + off.y)
                    b.hw = w / 2
                    b.hh = h / 2
                case .rotate:
                    var angle = atan2(p.y - a.start.c.y, p.x - a.start.c.x) + .pi / 2
                    if angle > .pi { angle -= 2 * .pi }
                    // snap to straight angles
                    let quarter = CGFloat.pi / 2
                    let snapped = (angle / quarter).rounded() * quarter
                    if abs(angle - snapped) < 0.07 { angle = snapped }
                    if abs(angle) < 0.001 { angle = 0 }
                    b.angle = angle
                }
                if let id = a.zoneId {
                    onZoneChange(id, rectN(b, size), Float(b.angle))
                } else {
                    let r = rectN(b, size)
                    onStudyAreaChange(RectN(left: max(0, r.left), top: max(0, r.top), right: min(1, r.right), bottom: min(1, r.bottom)))
                }
            }
            .onEnded { _ in
                dragStarted = false
                active = nil
                pinching = pinchStart != nil
            }
    }
}
