import SwiftUI
import TrafficCore

/// "Validate Detections": the image of every vehicle counted in one box with its class and confidence.
/// Wrong detections are removed with the trash button; a wrong class is fixed from the tile's menu.
struct ValidationView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID
    let zoneId: Int
    @State private var filter: VehicleClass?

    private var record: SessionRecord? { model.sessions.first(where: { $0.id == sessionId }) }

    var body: some View {
        NavigationStack {
            let events = (record?.events ?? []).filter { $0.zoneId == zoneId }
            let classes = VehicleClass.allCases.filter { c in events.contains { $0.cls == c } }
            let shown = events.filter { filter == nil || $0.cls == filter }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All \(events.count)", selected: filter == nil) { filter = nil }
                            ForEach(classes, id: \.self) { c in
                                chip("\(c.label) \(events.filter { $0.cls == c }.count)", selected: filter == c) { filter = c }
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text("No detections.").foregroundColor(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(shown, id: \.trackId) { e in tile(e) }
                    }
                    Text("Images are kept for the first \(AnalysisEngine.maxThumbnails) vehicles of a session, only on this device.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(16)
            }
            .navigationTitle(record?.zones.first(where: { $0.id == zoneId })?.name ?? "Validate Detections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func chip(_ text: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Theme.orange : Theme.peach, in: Capsule())
                .foregroundColor(selected ? .white : Theme.ink)
        }
    }

    private func tile(_ e: CountEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = model.thumbnail(sessionId, trackId: e.trackId) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.15).overlay(ClassIcon(cls: e.cls, size: 26))
                    }
                }
                .frame(height: 90)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button { model.deleteEvent(sessionId, zoneId: zoneId, trackId: e.trackId) } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.red, in: Circle())
                }
                .padding(4)
            }
            Menu {
                ForEach(VehicleClass.allCases, id: \.self) { c in
                    Button { model.reclassify(sessionId, trackId: e.trackId, to: c) } label: {
                        Text((c == e.cls ? "✓ " : "") + c.label)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    ClassIcon(cls: e.cls, size: 12)
                    Text(e.cls.label).font(.caption.weight(.semibold)).foregroundColor(.primary)
                    Image(systemName: "chevron.down").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            Text("\(e.score.map { "\(Int(($0 * 100).rounded())) %" } ?? "–") · \(e.direction)")
                .font(.caption2).foregroundColor(.secondary)
        }
    }
}
