import SwiftUI
import TrafficCore

/// Settings, laid out like the reference app: orange icons, model picker, FPS overlay, object types, sound.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Object Detection") {
                    Picker(selection: Binding(get: { model.detectionModel }, set: { model.setDetectionModel($0) })) {
                        ForEach(DetectionModel.allCases) { Text($0.title).tag($0) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Detection Model")
                                Text("Higher accuracy is slower").font(.caption).foregroundColor(.secondary)
                            }
                        } icon: { Image(systemName: "cpu") }
                    }
                    .disabled(model.running)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Confidence Threshold", systemImage: "slider.horizontal.3")
                            Spacer()
                            Text("\(Int((model.confidence * 100).rounded())) %").foregroundColor(Theme.orange)
                        }
                        Slider(value: $model.confidence, in: 0.1...0.9, step: 0.05)
                        Text("Lower finds more vehicles but also more false detections.").font(.caption).foregroundColor(.secondary)
                    }

                    Toggle(isOn: $model.saveImages) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save Object Images")
                                Text("For Validate Detections, kept on this device")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        } icon: { Image(systemName: "photo.on.rectangle") }
                    }
                    if model.saveImages {
                        NavigationLink {
                            ImagesByTypeView()
                        } label: {
                            HStack {
                                Label("Images by Type", systemImage: "square.grid.2x2")
                                Spacer()
                                Text(model.imageLimit == 0 ? "No limit" : "\(model.imageLimit) per type").foregroundColor(Theme.orange)
                            }
                        }
                    }

                    Toggle(isOn: $model.showFps) {
                        Label("FPS Overlay", systemImage: "speedometer")
                    }

                    NavigationLink {
                        ObjectTypesView()
                    } label: {
                        HStack {
                            Label("Detected Object Types", systemImage: "car")
                            Spacer()
                            Text("\(model.enabledClasses.count)").foregroundColor(Theme.orange)
                        }
                    }

                    Toggle(isOn: $model.soundOn) {
                        Label("Sound Effects", systemImage: "speaker.wave.2")
                    }

                    Toggle(isOn: $model.restScreen) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Rest Screen While Counting")
                                Text("After 30 s without touching, the screen dims and shows only the counts (tap to wake). Less heat and battery; counting is not affected.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        } icon: { Image(systemName: "moon") }
                    }
                }

                Section {
                    Toggle(isOn: $model.fichaMode) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("E50 Form (by axles)")
                                Text("Trucks classified as C-2G, C-3-4, C5 or ≥C6 after the session; PDF like the paper form")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        } icon: { Image(systemName: "tablecells") }
                    }
                } header: {
                    Text("Count Form")
                } footer: {
                    Text("Every truck keeps its photo so it can be classified by axles in the results (Classify trucks). Vans are counted as AUTOS/CAMIONETAS.")
                }

                Section("About") {
                    Label("Everything runs on this device. Nothing is uploaded; videos are never stored.", systemImage: "lock.shield")
                        .font(.footnote)
                }
            }
            .tint(Theme.orange)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Which counted vehicles keep their photo, per class, and the per-class limit.
struct ImagesByTypeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section(footer: Text("Sample keeps 1 vehicle in every \(ImagePolicy.sampleEvery), spread over the whole session: enough to check the counts without thousands of photos. Photos are written as soon as they are taken.")) {
                ForEach(VehicleClass.allCases.filter { model.enabledClasses.contains($0) }, id: \.self) { c in
                    let forced = model.fichaMode && (c == .truck || c == .bus)
                    Picker(selection: Binding(get: { forced ? .all : model.imagePolicy[c] ?? .all },
                                              set: { model.imagePolicy[c] = $0 })) {
                        ForEach(ImagePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        HStack(spacing: 12) {
                            ClassIcon(cls: c, size: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.label)
                                if forced { Text("Always all, no limit (E50 form)").font(.caption).foregroundColor(.secondary) }
                            }
                        }
                    }
                    .disabled(forced)
                }
            }
            Section(footer: Text("No limit keeps every photo of the session: about 25 KB each, so 4 hours of heavy traffic can take 200 MB. Photos stop if the phone has less than 1 GB free.")) {
                Picker(selection: $model.imageLimit) {
                    ForEach(AppModel.imageLimits, id: \.self) { n in Text(n == 0 ? "No limit" : "\(n)").tag(n) }
                } label: {
                    Label("Limit per Type", systemImage: "number")
                }
            }
        }
        .tint(Theme.orange)
        .navigationTitle("Images by Type")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ObjectTypesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section(footer: Text("Only the selected types are tracked and counted.")) {
                ForEach(VehicleClass.allCases, id: \.self) { c in
                    Button { model.toggleClass(c) } label: {
                        HStack(spacing: 12) {
                            ClassIcon(cls: c, size: 20)
                            Text(c.label).foregroundColor(.primary)
                            Spacer()
                            if model.enabledClasses.contains(c) {
                                Image(systemName: "checkmark").foregroundColor(Theme.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Detected Object Types")
        .navigationBarTitleDisplayMode(.inline)
    }
}
