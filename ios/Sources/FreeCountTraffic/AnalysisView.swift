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
    @State private var lastEventCount = 0

    private var events: [CountEvent] { model.liveEvents }

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
        // any tap wakes the screen from rest and restarts its countdown
        .simultaneousGesture(TapGesture().onEnded { model.touched() })
        .onChange(of: model.zones) { _ in model.touched() }
        .overlay { if model.resting { RestView(source: source).environmentObject(model) } }
        .onAppear { model.enterAnalysis(source) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .onChange(of: events.count) { count in
            // only new vehicles beep (not Reset clearing the counts)
            if count > lastEventCount && model.soundOn { AudioServicesPlaySystemSound(1057) }
            lastEventCount = count
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

    private var frameAspect: CGFloat { model.frameAspect ?? 16.0 / 9.0 }

    private func frameView(fillWidth: Bool) -> some View {
        LivePicture(live: model.live, fillWidth: fillWidth)
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

                // after Stop: Reset clears the counts and brings back "Start counting" (boxes are kept)
                if finishedSessionId != nil {
                    Button { model.resetSession() } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Color.red, in: Capsule())
                    }
                    .frame(maxWidth: .infinity)
                }
    
                Text("Boxes").font(.title2.weight(.bold)).padding(.top, 6)
                ForEach(Array(model.zones.enumerated()), id: \.element.id) { i, z in boxRow(i, z) }
                Button { model.addZone() } label: { Text("+ Add box") }
                    .buttonStyle(.bordered)
                Text("Drag a box to move it, any corner dot to resize it and the round arrow above it to rotate it (it snaps every 15°; Box settings has an exact rotation slider). A moving vehicle is counted when its centre enters the box. Use the arrows button to count only one direction. Pinch or tap the % button to zoom (drag the picture to look around; a vertical picture fills the width, drag it up or down to see the rest); Study area limits the analysis to part of the picture, which helps with distant vehicles.")
                    .font(.caption)
    
                boxSettings
    
                if !events.isEmpty {
                    Text("Results").font(.title2.weight(.bold)).padding(.top, 8)
                    ResultsPanel(events: events, zones: model.zones)
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
            if model.videoURL != nil { videoStartTime }
            if model.running, let p = model.progress { ProgressView(value: p) }
        }
    }

    /// Real time the video starts at: the 15-minute periods (and the E50 form) follow the clock with it.
    @ViewBuilder private var videoStartTime: some View {
        if let start = model.clockStart {
            DatePicker(selection: Binding(get: { start }, set: { model.setVideoStart($0) }),
                       displayedComponents: [.date, .hourAndMinute]) {
                Label("Real start time", systemImage: "clock")
            }
            .disabled(model.running)
            Text(model.videoStartFromFile
                 ? "Taken from the video's recording date. Check it: videos sent by WhatsApp or edited may carry the time they were exported."
                 : "Set by you. The 15-minute periods follow this time.")
                .font(.caption).foregroundColor(.secondary)
        } else {
            HStack {
                Label("No recording time in this video", systemImage: "clock.badge.questionmark")
                    .font(.subheadline)
                    .foregroundColor(model.fichaMode ? Theme.orange : .primary)
                Spacer()
                Button("Set time") {
                    // now, to the minute: the user then picks the real date and time
                    model.setVideoStart(Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60))
                }
                .buttonStyle(.bordered)
                .disabled(model.running)
            }
            Text(model.fichaMode
                 ? "The E50 form needs the real time the video starts (write it down in the field when you start recording)."
                 : "Optional: without it the periods start at 00:00.")
                .font(.caption).foregroundColor(.secondary)
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
        case .rtsp: return model.rtspActive != nil && model.frameAspect != nil
        }
    }

    /// Session that was just stopped (its results can be opened, or Reset to count again).
    private var finishedSessionId: UUID? {
        guard !model.running, let id = model.lastSessionId, model.sessions.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Full-width orange bar like the reference app: "■ Stop - 00:01:31s", then "Show results" once stopped.
    private var actionButton: some View {
        Button {
            if model.running {
                model.stop()
            } else if let id = finishedSessionId {
                model.openFinishedResults()
                onResults(id)
            } else {
                model.start()
            }
        } label: {
            HStack(spacing: 10) {
                if model.running {
                    Image(systemName: "stop.fill")
                    Text("Stop - \(clock(model.elapsedMs))s")
                } else if finishedSessionId != nil {
                    Image(systemName: "list.clipboard")
                    Text("Show results")
                } else {
                    Image(systemName: "record.circle")
                    Text("Start counting")
                }
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.orange.opacity(model.running || finishedSessionId != nil || canStart ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!model.running && finishedSessionId == nil && !canStart)
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
            let degrees = Int((z.rotation * 180 / .pi).rounded())
            HStack {
                Text("Rotation")
                Spacer()
                Text("\(degrees)°").monospacedDigit()
                Button("Reset") { model.setAngle(z.id, 0) }
                    .buttonStyle(.bordered)
                    .disabled(degrees == 0)
            }
            Slider(value: Binding(
                get: { Double(z.rotation * 180 / .pi) },
                set: { model.setAngle(z.id, Float($0 * .pi / 180)) }
            ), in: -180...180, step: 1)
            if model.zones.count > 1 {
                Button(role: .destructive) { model.deleteZone(z.id) } label: { Text("Delete \(z.name)") }
            }
        }
    }

}

/// The picture with its boxes: the only part of the analysis screen redrawn for every frame.
struct LivePicture: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var live: LiveFrame
    let fillWidth: Bool

    var body: some View {
        let s = live.snapshot
        FrameView(
            frame: s?.frame,
            tracks: s?.tracks ?? [],
            trails: s?.trails ?? [:],
            fps: model.running && model.showFps ? s?.fps : nil,
            zones: model.zones,
            counts: Dictionary(grouping: model.liveEvents, by: { $0.zoneId }).mapValues { $0.count },
            selectedId: model.selectedZoneId,
            studyArea: model.studyArea,
            onSelect: { model.selectedZoneId = $0 },
            onZoneChange: { model.setRect($0, $1, angle: $2) },
            onStudyAreaChange: { model.setStudyArea($0) },
            fillWidth: fillWidth
        )
    }
}

/// Rest screen while counting: dark and dimmed, with only the counts (frames are still analysed). A tap wakes it.
struct RestView: View {
    @EnvironmentObject var model: AppModel
    let source: SourceKind

    var body: some View {
        let unique = Summary.unique(model.liveEvents)
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Label("Counting · \(clock(model.elapsedMs))", systemImage: "moon.fill")
                    .font(.headline)
                    .foregroundColor(Theme.orange)
                Text("\(unique.count)").font(.system(size: 76, weight: .bold).monospacedDigit())
                Text("vehicles").font(.subheadline).foregroundColor(.gray)
                VStack(spacing: 6) {
                    ForEach(Summary.of(model.liveEvents, zones: model.zones), id: \.zoneId) { s in
                        HStack {
                            Text(s.zoneName).lineLimit(1)
                            Spacer()
                            Text("\(s.total)").monospacedDigit().fontWeight(.semibold)
                        }
                    }
                }
                .frame(maxWidth: 280)
                if source == .video, let p = model.progress { ProgressView(value: p).frame(maxWidth: 280).tint(Theme.orange) }
                Text("Screen resting to save heat and battery.\nTap to show the picture.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundColor(.gray)
                    .padding(.top, 8)
            }
            .foregroundColor(.white)
            .padding(32)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.touched() }
    }
}
