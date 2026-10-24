import SwiftUI

/// Header of the E50 form before making its PDF. The values are kept with the session and proposed for the next one.
struct FichaFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State var info: FichaInfo
    /// Trucks still without their axle class (the PDF can be made anyway, they show as SIN CLASIFICAR).
    let pending: Int
    let onDone: (FichaInfo) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Header") {
                    TextField("Title", text: $info.title, axis: .vertical)
                    TextField("Estación de aforo", text: $info.station)
                    TextField("Condición climática", text: $info.weather)
                    TextField("Aforador", text: $info.observer)
                    TextField("Coordinador", text: $info.coordinator)
                }
                if pending > 0 {
                    Section {
                        Label("\(pending) truck(s) are not classified by axles yet: they will show as SIN CLASIFICAR.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundColor(Theme.orange)
                            .font(.subheadline)
                    }
                }
                Section {
                    Text("Date, start and end time and the movements (box and direction) come from the session.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("E50 form")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make PDF") {
                        onDone(info)
                        dismiss()
                    }
                }
            }
        }
    }
}
