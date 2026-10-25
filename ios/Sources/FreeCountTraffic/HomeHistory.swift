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
                big("RTSP stream") { onSource(.rtsp) }
                Text("Connect to an IP camera (H.264 or H.265) on the same network or the internet.").font(.caption)
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
    @State private var classifyTrucks = false
    @State private var fichaForm = false
    /// Ficha PDF made from the form sheet, shared once that sheet has closed.
    @State private var fichaPdf: URL?

    private static func meta(_ r: SessionRecord) -> String {
        var meta = DateFormatter.localizedString(from: r.startedAt, dateStyle: .medium, timeStyle: .short)
        meta += "\nDuration: \(CsvExporter.clock(Int64(r.durationMs))) · \(r.source)"
        if let lat = r.latitude, let lon = r.longitude { meta += String(format: "\nLocation: %.5f, %.5f", lat, lon) }
        if let device = r.deviceSummary { meta += "\n" + device }
        return meta
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "Tracking Results", onBack: onBack, trailing: AnyView(
                Menu {
                    Button { renameStart() } label: { Label("Rename", systemImage: "pencil") }
                    Button { exportCsv() } label: { Label("Export CSV", systemImage: "tablecells") }
                    Button { exportPdf() } label: { Label("Export PDF", systemImage: "doc.richtext") }
                    if model.fichaMode {
                        Button { fichaForm = true } label: { Label("Export E50 form (PDF)", systemImage: "tablecells.badge.ellipsis") }
                    }
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

                        if model.fichaMode { fichaCard(r) }

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
                            let t = r.eventTimes(e)
                            let when: String = [t.video, t.clock ?? CsvExporter.clock(e.timeMs)].compactMap { $0 }.joined(separator: "  ")
                            Text("\(when)  \(e.zoneName)  \(e.cls.label) \(e.direction)\(speed)")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .sheet(isPresented: $showGraph) { ChartsView(record: r) }
                .sheet(item: $validate) { t in
                    ValidationView(sessionId: id, zoneId: t.id, ficha: model.fichaMode).environmentObject(model)
                }
                .sheet(isPresented: $classifyTrucks) {
                    ValidationView(sessionId: id, zoneId: nil, ficha: true, onlyUnclassified: pendingTrucks(r) > 0)
                        .environmentObject(model)
                }
                .sheet(isPresented: $fichaForm, onDismiss: {
                    if let url = fichaPdf { share = ShareItem(urls: [url]); fichaPdf = nil }
                }) {
                    FichaFormView(info: r.ficha ?? model.lastFichaInfo, pending: pendingTrucks(r)) { info in
                        model.setFichaInfo(id, info)
                        if let saved = record { fichaPdf = try? FichaPDF.pdf(saved, info) }
                    }
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
        if let r = record, let urls = try? Exporter.csv(r, ficha: model.fichaMode) { share = ShareItem(urls: urls) }
    }

    /// Trucks of the session still without their axle class (each vehicle once, whatever boxes it crossed).
    private func pendingTrucks(_ r: SessionRecord) -> Int {
        Summary.unique(r.events).filter { FichaCategory($0) == .sinClasificar }.count
    }

    /// E50 form: trucks to classify by axles, and the PDF laid out like the paper form.
    private func fichaCard(_ r: SessionRecord) -> some View {
        let pending = pendingTrucks(r)
        return VStack(alignment: .leading, spacing: 8) {
            Label("E50 form (by axles)", systemImage: "tablecells").font(.headline)
            Text(pending > 0
                 ? "\(pending) truck(s) still to classify by axles. Until then they are reported as SIN CLASIFICAR."
                 : "Every truck is classified.")
                .font(.subheadline)
                .foregroundColor(pending > 0 ? Theme.orange : .secondary)
            HStack {
                Button { classifyTrucks = true } label: { Label("Classify trucks", systemImage: "truck.box") }
                    .buttonStyle(.bordered)
                Button { fichaForm = true } label: { Label("Form PDF", systemImage: "doc.richtext") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.peach.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .foregroundColor(.primary)
    }

    private func exportPdf() {
        if let r = record, let u = try? Exporter.pdf(r) { share = ShareItem(urls: [u]) }
    }
}
