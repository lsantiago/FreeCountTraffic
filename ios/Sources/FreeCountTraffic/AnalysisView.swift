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
    var onResults: (UUID) -> Void = { _ in }

    @State private var pickerItem: PhotosPickerItem?
    @State private var showFiles = false
    @State private var lengthText = ""
    @State private var lengthZoneId: Int?
    @State private var showSettings = false

    private var events: [CountEvent] { model.snapshot?.events ?? [] }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                TopBar(title: Self.title(source), onBack: {
                    model.leaveAnalysis()
                    onBack()
                }, trailing: AnyView(
                    Button { showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 18)) }
                ))
                // the picture never takes the whole screen (vertical videos, phone turned sideways): the controls
                // always keep their own scrollable space next to or below it
                if landscape {
                    HStack(alignment: .top, spacing: 0) {
                        frameView(fillWidth: false).frame(width: geo.size.width * 0.6)
                        controlsScroll
                    }
                } else {
                    // a vertical picture fills the screen width (cropped top and bottom, drag to see the rest)
                    frameView(fillWidth: true).frame(height: min(geo.size.height * 0.48, geo.size.width / frameAspect))
                    controlsScroll
                }
            }
        }
        .onAppear { model.selectSource(source) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .onChange(of: events.count) { _ in
            if model.soundOn { AudioServicesPlaySystemSound(1057) }
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: MovieFile.self) { model.loadVideo(movie.url, displayName: "Video") }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                model.loadVideo(dest, displayName: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private static func title(_ source: SourceKind) -> String {
        switch source {
        case .camera: return "Live Camera"
        case .video: return "Video File"
        case .rtsp: return "RTSP Stream"
        }
    }

    private var frameAspect: CGFloat {
        guard let f = model.snapshot?.frame, f.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(f.width) / CGFloat(f.height)
    }

    private func frameView(fillWidth: Bool) -> some View {
        FrameView(
            frame: model.snapshot?.frame,
            tracks: model.snapshot?.tracks ?? [],
            trails: model.snapshot?.trails ?? [:],
            fps: model.running && model.showFps ? model.snapshot?.fps : nil,
            zones: model.zones,
            counts: Dictionary(grouping: events, by: { $0.zoneId }).mapValues { $0.count },
            selectedId: model.selectedZoneId,
            studyArea: model.studyArea,
            onSelect: { model.selectedZoneId = $0 },
            onZoneChange: { model.setRect($0, $1, angle: $2) },
            onStudyAreaChange: { model.setStudyArea($0) },
            fillWidth: fillWidth
        )
    }

    private var controlsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !model.modelReady { Text("Loading detection model…").font(.caption) }
                if let m = model.message { Text(m).font(.subheadline).foregroundColor(Theme.orange) }
    
                if source == .video { videoControls }
                if source == .rtsp { rtspControls }
    
                HStack(spacing: 8) {
                    Image(systemName: "pencil").foregroundColor(Theme.orange)
                    TextField(source == .camera ? "Session name (default: address)" : "Session name",
                              text: Binding(get: { model.sessionName }, set: { model.setSessionName($0) }))
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.running)
                }
    
                actionButton
    
                if !model.running, let id = model.lastSessionId, model.sessions.contains(where: { $0.id == id }) {
                    Button { onResults(id) } label: {
                        Label("Open results: graph, validation, export", systemImage: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
    
                Text("Boxes").font(.title2.weight(.bold)).padding(.top, 6)
                ForEach(Array(model.zones.enumerated()), id: \.element.id) { i, z in boxRow(i, z) }
                Button { model.addZone() } label: { Text("+ Add box") }
                    .buttonStyle(.bordered)
                Text("Drag a box to move it, any corner dot to resize it and the round arrow above it to rotate it. A moving vehicle is counted when its centre enters the box. Use the arrows button to count only one direction. Pinch or tap the % button to zoom (drag the picture to look around; a vertical picture fills the width, drag it up or down to see the rest); Study area limits the analysis to part of the picture, which helps with distant vehicles.")
                    .font(.caption)
    
                boxSettings
    
                if !events.isEmpty {
                    Text("Results").font(.title2.weight(.bold)).padding(.top, 8)
                    ResultsPanel(events: events, zones: model.zones)
                }
                Color.clear.frame(height: 0)
                    .onChange(of: model.lastSessionId) { id in
                        // the CI autotest stays on this screen
                        if let id, !model.autotestRequested { onResults(id) }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

    private var rtspControls: some View {
        HStack(spacing: 8) {
            TextField("rtsp://user:pass@host:554/stream", text: $model.rtspUrl)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { model.connectRtsp() }
            Button { model.connectRtsp() } label: { Text(model.rtspActive == nil ? "Connect" : "Reconnect") }
                .buttonStyle(.bordered)
        }
    }

    private var canStart: Bool {
        guard model.modelReady else { return false }
        switch source {
        case .camera: return true
        case .video: return model.videoURL != nil
        case .rtsp: return model.rtspActive != nil && model.snapshot != nil
        }
    }

    /// Full-width orange bar like the reference app: "■ Stop - 00:01:31s".
    private var actionButton: some View {
        Button {
            if model.running { model.stop() } else { model.start() }
        } label: {
            HStack(spacing: 10) {
                if model.running {
                    Image(systemName: "stop.fill")
                    Text("Stop - \(clock(model.elapsedMs))s")
                } else {
                    Image(systemName: "record.circle")
                    Text("Start counting")
                }
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.orange.opacity(model.running || canStart ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!model.running && !canStart)
    }

    private func boxRow(_ i: Int, _ z: Zone) -> some View {
        let selected = z.id == model.selectedZoneId
        var byClass: [VehicleClass: Int] = [:]
        for e in events where e.zoneId == z.id { byClass[e.cls, default: 0] += 1 }
        let header = HStack(spacing: 10) {
            Swatch(color: Theme.zone(i))
            Text(z.name).font(.body).lineLimit(1).truncationMode(.tail)
            DirectionMenu(current: z.direction) { model.setDirection(z.id, $0) }
                .disabled(model.running)
        }
        let counts = Group {
            if byClass.isEmpty { Text("0").font(.subheadline) } else { ClassChips(byClass: byClass) }
        }
        // counts on the same line while they fit, otherwise on their own line (large counts, several classes)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                header
                Spacer(minLength: 8)
                counts
            }
            VStack(alignment: .leading, spacing: 6) {
                header
                counts.padding(.leading, 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

}
