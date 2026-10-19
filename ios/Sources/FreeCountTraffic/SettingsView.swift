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
                                Text("For Validate Detections (first 500 per session, kept on this device)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        } icon: { Image(systemName: "photo.on.rectangle") }
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
