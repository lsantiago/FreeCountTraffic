import SwiftUI
import TrafficCore

/// Frame + live boxes + editable counting boxes. Coordinates are normalized to the frame.
struct FrameView: View {
    let frame: CGImage?
    let tracks: [Track]
    let zones: [Zone]
    let counts: [Int: Int]
    let selectedId: Int?
    let onSelect: (Int) -> Void
    let onRectChange: (Int, RectN) -> Void

    private struct Active {
        var id: Int
        var resize: Bool
        var last: CGSize
    }

    @State private var dragStarted = false
    @State private var active: Active?

    private let handle: Float = 0.07
    private let minSize: Float = 0.04

    private var aspect: CGFloat {
        guard let f = frame, f.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(f.width) / CGFloat(f.height)
    }

    var body: some View {
        ZStack {
            Color.black
            if let frame {
                Image(decorative: frame, scale: 1).resizable()
            }
            GeometryReader { geo in
                Canvas { ctx, size in draw(ctx, size) }
                    .contentShape(Rectangle())
                    .gesture(drag(geo.size))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    // MARK: drawing

    private func rect(_ r: RectN, _ size: CGSize) -> CGRect {
        CGRect(x: CGFloat(r.left) * size.width, y: CGFloat(r.top) * size.height,
               width: CGFloat(r.width) * size.width, height: CGFloat(r.height) * size.height)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        for t in tracks {
            let c = Theme.cls(t.cls)
            let r = rect(t.box, size)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(c), lineWidth: 1.5)
            let tag = t.cls.label.lowercased()
            let tagRect = CGRect(x: r.minX, y: r.minY - 13, width: CGFloat(tag.count) * 5.6 + 8, height: 12)
            ctx.fill(Path(roundedRect: tagRect, cornerRadius: 3), with: .color(c.opacity(0.9)))
            ctx.draw(Text(tag).font(.system(size: 9, weight: .semibold)).foregroundColor(.white),
                     at: CGPoint(x: tagRect.minX + 4, y: tagRect.midY), anchor: .leading)
        }
        for (i, z) in zones.enumerated() {
            let c = Theme.zone(i)
            let selected = z.id == selectedId
            let r = rect(z.rect, size)
            let path = Path(roundedRect: r, cornerRadius: 6)
            ctx.fill(path, with: .color(c.opacity(selected ? 0.40 : 0.28)))
            ctx.stroke(path, with: .color(c), lineWidth: selected ? 3 : 2)

            // big count badge in the middle of the box
            let count = "\(counts[z.id] ?? 0)"
            let bw = CGFloat(count.count) * 11 + 16
            let badge = CGRect(x: r.midX - bw / 2, y: r.midY - 13, width: bw, height: 26)
            ctx.fill(Path(roundedRect: badge, cornerRadius: 8), with: .color(Color(white: 0.12, opacity: 0.67)))
            ctx.draw(Text(count).font(.system(size: 16, weight: .bold)).foregroundColor(.white),
                     at: CGPoint(x: badge.midX, y: badge.midY))

            ctx.draw(Text(z.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white),
                     at: CGPoint(x: r.minX + 6, y: r.minY + 9), anchor: .leading)
            if selected {
                let h = CGPoint(x: r.maxX, y: r.maxY)
                ctx.fill(Path(ellipseIn: CGRect(x: h.x - 9, y: h.y - 9, width: 18, height: 18)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: h.x - 7, y: h.y - 7, width: 14, height: 14)), with: .color(c))
            }
        }
    }

    // MARK: editing gesture

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard size.width > 0, size.height > 0 else { return }
                if !dragStarted {
                    dragStarted = true
                    let nx = Float(v.startLocation.x / size.width)
                    let ny = Float(v.startLocation.y / size.height)
                    // the selected box wins ties
                    let ordered = zones.sorted { a, b in (a.id == selectedId ? 1 : 0) > (b.id == selectedId ? 1 : 0) }
                    if let z = ordered.first(where: { abs(nx - $0.rect.right) < handle && abs(ny - $0.rect.bottom) < handle }) {
                        active = Active(id: z.id, resize: true, last: .zero)
                        onSelect(z.id)
                    } else if let z = ordered.first(where: { $0.rect.contains(nx, ny) }) {
                        active = Active(id: z.id, resize: false, last: .zero)
                        onSelect(z.id)
                    }
                }
                guard let a = active, let z = zones.first(where: { $0.id == a.id }) else { return }
                let dx = Float((v.translation.width - a.last.width) / size.width)
                let dy = Float((v.translation.height - a.last.height) / size.height)
                active?.last = v.translation
                let r = z.rect
                let next: RectN
                if a.resize {
                    next = RectN(left: r.left, top: r.top,
                                 right: min(max(r.right + dx, r.left + minSize), 1),
                                 bottom: min(max(r.bottom + dy, r.top + minSize), 1))
                } else {
                    let mx = min(max(dx, -r.left), 1 - r.right)
                    let my = min(max(dy, -r.top), 1 - r.bottom)
                    next = r.shifted(mx, my)
                }
                onRectChange(z.id, next)
            }
            .onEnded { _ in
                dragStarted = false
                active = nil
            }
    }
}
