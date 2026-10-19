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
                Text("Count vehicles and estimate their speed with on-device AI. Draw boxes on the image and press start. Nothing is uploaded and videos are never stored: only counts and small images of the counted vehicles for validation.")
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
    let urls: [URL]
}

private struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ValidateTarget: Identifiable {
    let id: Int // zone id
}

struct SessionDetailView: View {
    @EnvironmentObject var model: AppModel
    let id: UUID
    let onBack: () -> Void
    @State private var share: ShareItem?
    @State private var showGraph = false
    @State private var validate: ValidateTarget?
    @State private var renaming = false
    @State private var newName = ""

    private static func meta(_ r: SessionRecord) -> String {
        var meta = DateFormatter.localizedString(from: r.startedAt, dateStyle: .medium, timeStyle: .short)
        meta += "\nDuration: \(CsvExporter.clock(Int64(r.durationMs))) · \(r.source)"
        if let lat = r.latitude, let lon = r.longitude { meta += String(format: "\nLocation: %.5f, %.5f", lat, lon) }
        return meta
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Tracking Results", onBack: onBack, trailing: AnyView(
                Menu {
                    Button { renameStart() } label: { Label("Rename", systemImage: "pencil") }
                    Button { exportCsv() } label: { Label("Export CSV", systemImage: "tablecells") }
                    Button { exportPdf() } label: { Label("Export PDF", systemImage: "doc.richtext") }
                    Button(role: .destructive) { model.deleteSession(id); onBack() } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 20)) }
            ))
            if let r = model.sessions.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Button { renameStart() } label: {
                            HStack(spacing: 6) {
                                Text(r.name).font(.title2.weight(.bold)).foregroundColor(.primary)
                                Image(systemName: "pencil").font(.system(size: 15))
                            }
                        }
                        .frame(maxWidth: .infinity)

                        Button { showGraph = true } label: {
                            Label("Show Graph", systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        ResultsPanel(events: r.events, zones: r.zones, onValidate: { validate = ValidateTarget(id: $0) })

                        Text(Self.meta(r)).font(.caption).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 8)

                        HStack {
                            Button { exportCsv() } label: { Text("Export CSV") }
                                .buttonStyle(.borderedProminent)
                            Button { exportPdf() } label: { Text("Export PDF") }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        Text("CSV export includes every vehicle and the 15-minute volume table.").font(.caption)
                            .frame(maxWidth: .infinity)

                        Text("Vehicles").font(.headline).padding(.top, 8)
                        ForEach(Array(r.events.enumerated()), id: \.offset) { _, e in
                            let speed = e.speedKmh.map { String(format: " · %.0f km/h", $0) } ?? ""
                            Text("\(CsvExporter.clock(e.timeMs, startEpochMs: r.startEpochMs))  \(e.zoneName)  \(e.cls.label) \(e.direction)\(speed)")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .sheet(isPresented: $showGraph) { ChartsView(record: r) }
                .sheet(item: $validate) { t in
                    ValidationView(sessionId: id, zoneId: t.id).environmentObject(model)
                }
            } else {
                Text("Session not found.").padding(20)
            }
        }
        .sheet(item: $share) { item in ShareSheet(urls: item.urls) }
        .onChange(of: model.autotestStage) { stage in
            switch stage {
            case 2: showGraph = true
            case 3: showGraph = false
            case 4: if let z = record?.zones.first { validate = ValidateTarget(id: z.id) }
            default: break
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.renameSession(id, newName) }
        }
    }

    private var record: SessionRecord? { model.sessions.first(where: { $0.id == id }) }

    private func renameStart() {
        newName = record?.name ?? ""
        renaming = true
    }

    private func exportCsv() {
        if let r = record, let urls = try? Exporter.csv(r) { share = ShareItem(urls: urls) }
    }

    private func exportPdf() {
        if let r = record, let u = try? Exporter.pdf(r) { share = ShareItem(urls: [u]) }
    }
}
