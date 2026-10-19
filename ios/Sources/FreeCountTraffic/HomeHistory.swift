import SwiftUI
import TrafficCore
import UIKit

struct HomeView: View {
    let onSource: (SourceKind) -> Void
    let onHistory: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Free Count Traffic").font(.largeTitle.weight(.bold))
                Text("Count vehicles and estimate their speed with on-device AI. Draw boxes on the image and press start. Nothing is uploaded: no video or photo is stored, only counts.")
                    .font(.body)
                Color.clear.frame(height: 4)
                big("Camera") { onSource(.camera) }
                Text("Use the back camera of this phone, mounted still on a tripod or window.").font(.caption)
                big("Video file") { onSource(.video) }
                Text("Analyse a recorded video. Speed uses exact video timestamps.").font(.caption)
                big("RTSP stream") {}.disabled(true)
                Text("RTSP streams are not available on iOS yet (Android only).").font(.caption)
                Color.clear.frame(height: 4)
                Button(action: onHistory) { Text("History").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.bordered)
            }
            .padding(20)
        }
    }

    private func big(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.borderedProminent)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    let onBack: () -> Void
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "History", onBack: onBack)
            if model.sessions.isEmpty {
                Text("No sessions yet.").padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.sessions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.weight(.semibold))
                            Text("\(s.source) · \(s.durationMs / 1000) s · \(DateFormatter.localizedString(from: s.startedAt, dateStyle: .medium, timeStyle: .short))")
                                .font(.caption)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(s.id) }
                    }
                }
                .padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SessionDetailView: View {
    @EnvironmentObject var model: AppModel
    let id: UUID
    let onBack: () -> Void
    @State private var share: ShareItem?

    private static func meta(_ r: SessionRecord) -> String {
        var meta = DateFormatter.localizedString(from: r.startedAt, dateStyle: .medium, timeStyle: .short)
        meta += "\nDuration: \(r.durationMs / 1000) s · \(r.source)"
        if let lat = r.latitude, let lon = r.longitude { meta += String(format: "\nLocation: %.5f, %.5f", lat, lon) }
        return meta
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Tracking Results", onBack: onBack)
            if let r = model.sessions.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(r.name).font(.title2.weight(.bold)).frame(maxWidth: .infinity)
                        ResultsPanel(events: r.events, zones: r.zones)

                        Text(Self.meta(r)).font(.caption).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 8)

                        HStack {
                            Button { if let u = try? Exporter.csv(r) { share = ShareItem(url: u) } } label: { Text("Export CSV") }
                                .buttonStyle(.borderedProminent)
                            Button { if let u = try? Exporter.pdf(r) { share = ShareItem(url: u) } } label: { Text("Export PDF") }
                                .buttonStyle(.borderedProminent)
                        }
                        Button(role: .destructive) { model.deleteSession(id); onBack() } label: { Text("Delete session") }

                        Text("Vehicles").font(.headline)
                        ForEach(Array(r.events.enumerated()), id: \.offset) { _, e in
                            let speed = e.speedKmh.map { String(format: " · %.0f km/h", $0) } ?? ""
                            Text(String(format: "%.1fs  %@  %@ %@%@", Double(e.timeMs) / 1000, e.zoneName, e.cls.label, e.direction, speed))
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            } else {
                Text("Session not found.").padding(20)
            }
        }
        .sheet(item: $share) { item in ShareSheet(url: item.url) }
    }
}
