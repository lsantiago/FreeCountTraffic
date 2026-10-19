import AudioToolbox
import PhotosUI
import SwiftUI
import TrafficCore
import UniformTypeIdentifiers

/// A video picked from the Photos library, copied to a temp file so it stays readable.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

private func clock(_ ms: Int64) -> String {
    let s = Int(ms / 1000)
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

struct AnalysisView: View {
    @EnvironmentObject var model: AppModel
    let source: SourceKind
    let onBack: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var lengthText = ""
    @State private var lengthZoneId: Int?

    private var events: [CountEvent] { model.snapshot?.events ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TopBar(title: source == .camera ? "Live Camera" : "Video File") {
                    model.leaveAnalysis()
                    onBack()
                }

                FrameView(
                    frame: model.snapshot?.frame,
                    tracks: model.snapshot?.tracks ?? [],
                    zones: model.zones,
                    counts: Dictionary(grouping: events, by: { $0.zoneId }).mapValues { $0.count },
                    selectedId: model.selectedZoneId,
                    onSelect: { model.selectedZoneId = $0 },
                    onRectChange: { model.setRect($0, $1) }
                )

                VStack(alignment: .leading, spacing: 10) {
                    if !model.modelReady { Text("Loading detection model…").font(.caption) }
                    if let m = model.message { Text(m).font(.subheadline).foregroundColor(Theme.orange) }

                    if source == .video { videoControls }

                    actionButton

                    Text("Boxes").font(.title2.weight(.bold)).padding(.top, 6)
                    ForEach(Array(model.zones.enumerated()), id: \.element.id) { i, z in boxRow(i, z) }
                    Button { model.addZone() } label: { Text("+ Add box") }
                        .buttonStyle(.bordered)
                    Text("Drag a box to move it, drag its white corner dot to resize. A vehicle is counted when it crosses the box.")
                        .font(.caption)

                    boxSettings
                    countSettings

                    if !events.isEmpty {
                        Text("Results").font(.title2.weight(.bold)).padding(.top, 8)
                        ResultsPanel(events: events, zones: model.zones)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .onAppear { model.selectSource(source) }
        .onChange(of: events.count) { _ in
            if model.soundOn { AudioServicesPlaySystemSound(1057) }
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: MovieFile.self) { model.loadVideo(movie.url) }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { model.loadVideo(dest) }
        }
    }

    // MARK: pieces

    private var videoControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PhotosPicker(selection: $pickerItem, matching: .videos) { Text("Choose from Photos…") }
                    .buttonStyle(.bordered)
                    .disabled(model.running)
                Button { showFiles = true } label: { Text("Choose from Files…") }
                    .buttonStyle(.bordered)
                    .disabled(model.running)
            }
            if model.running, let p = model.progress { ProgressView(value: p) }
        }
    }

    private var canStart: Bool { model.modelReady && (source == .camera || model.videoURL != nil) }

    private var actionButton: some View {
        HStack {
            Spacer()
            if model.running {
                Button { model.stop() } label: {
                    Text("■  Stop - \(clock(model.elapsedMs))").fontWeight(.semibold).padding(.horizontal, 18).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { model.start() } label: {
                    Text("Start counting").fontWeight(.semibold).padding(.horizontal, 18).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
            Spacer()
        }
    }

    private func boxRow(_ i: Int, _ z: Zone) -> some View {
        let selected = z.id == model.selectedZoneId
        var byClass: [VehicleClass: Int] = [:]
        for e in events where e.zoneId == z.id { byClass[e.cls, default: 0] += 1 }
        return HStack(spacing: 10) {
            Swatch(color: Theme.zone(i))
            Text(z.name).font(.body)
            Spacer()
            if byClass.isEmpty { Text("0").font(.subheadline) } else { ClassChips(byClass: byClass) }
        }
        .padding(10)
        .background(selected ? Theme.peach : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .foregroundColor(selected ? Theme.ink : .primary)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedZoneId = z.id }
    }

    @ViewBuilder private var boxSettings: some View {
        if let z = model.zones.first(where: { $0.id == model.selectedZoneId }) {
            Text("Box settings").font(.headline).padding(.top, 8)
            TextField("Name", text: Binding(get: { z.name }, set: { model.rename(z.id, $0) }))
                .textFieldStyle(.roundedBorder)
            TextField("Box length in meters (enables speed)", text: Binding(
                get: { lengthZoneId == z.id ? lengthText : (z.lengthMeters.map { String($0).replacingOccurrences(of: ".0", with: "") } ?? "") },
                set: { text in
                    lengthZoneId = z.id
                    lengthText = text
                    model.setLength(z.id, Float(text.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil })
                }
            ))
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
            Text("Real distance covered by the box's long side.").font(.caption)
            if model.zones.count > 1 {
                Button(role: .destructive) { model.deleteZone(z.id) } label: { Text("Delete \(z.name)") }
            }
        }
    }

    private var countSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Count").font(.headline).padding(.top, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(VehicleClass.allCases, id: \.self) { c in
                    let on = model.enabledClasses.contains(c)
                    Button { model.toggleClass(c) } label: {
                        Text(c.label).font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(on ? Theme.peach : Color.gray.opacity(0.12), in: Capsule())
                            .foregroundColor(on ? Theme.ink : .primary)
                    }
                }
            }
            Toggle("Beep when a vehicle is counted", isOn: $model.soundOn).tint(Theme.orange)
        }
    }
}
