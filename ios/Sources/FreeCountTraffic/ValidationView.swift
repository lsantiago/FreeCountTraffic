import SwiftUI
import TrafficCore

/// "Validate Detections": the image of every vehicle counted in one box (or in all of them) with its class and
/// confidence. Wrong detections are removed with the trash button; a wrong class is fixed from the tile's menu.
/// With the E50 form the classes are the form's columns, and trucks get their axle class here.
struct ValidationView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionId: UUID
    /// nil = every box (E50 form: classify all the trucks of the session)
    let zoneId: Int?
    var ficha = false

    private enum Filter: Hashable {
        case cls(VehicleClass)
        case category(FichaCategory)
    }

    private struct FilterChip: Hashable {
        let title: String
        let filter: Filter
    }

    @State private var filter: Filter?
    /// Vehicle shown enlarged (tap on a photo).
    @State private var enlarged: Enlarged?

    private struct Enlarged: Identifiable {
        let trackId: Int
        var id: Int { trackId }
    }

    init(sessionId: UUID, zoneId: Int?, ficha: Bool = false, onlyUnclassified: Bool = false) {
        self.sessionId = sessionId
        self.zoneId = zoneId
        self.ficha = ficha
        _filter = State(initialValue: onlyUnclassified ? .category(.sinClasificar) : nil)
    }

    private var record: SessionRecord? { model.sessions.first(where: { $0.id == sessionId }) }

    private func matches(_ e: CountEvent, _ f: Filter?) -> Bool {
        switch f {
        case nil: return true
        case .cls(let c): return e.cls == c
        case .category(let c): return FichaCategory(e) == c
        }
    }

    var body: some View {
        NavigationStack {
            // a vehicle crossing several boxes is shown once when every box is listed
            let all = record?.events ?? []
            // in time order, to go through a recorded video from start to end while validating
            let events = (zoneId.map { id in all.filter { $0.zoneId == id } } ?? Summary.unique(all)).sorted { $0.timeMs < $1.timeMs }
            let filters: [FilterChip] = ficha
                ? FichaCategory.allCases.compactMap { c in
                    let n = events.filter { FichaCategory($0) == c }.count
                    return n > 0 ? FilterChip(title: "\(c == .sinClasificar ? "⚠ " : "")\(c.rawValue) \(n)", filter: .category(c)) : nil
                }
                : VehicleClass.allCases.compactMap { c in
                    let n = events.filter { $0.cls == c }.count
                    return n > 0 ? FilterChip(title: "\(c.label) \(n)", filter: .cls(c)) : nil
                }
            let shown = events.filter { matches($0, filter) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All \(events.count)", selected: filter == nil) { filter = nil }
                            ForEach(filters, id: \.self) { f in chip(f.title, selected: filter == f.filter) { filter = f.filter } }
                        }
                    }
                    if ficha {
                        Text("Pick each truck's class by axles from its photo: C-2G, C-3-4, C5 or ≥C6. Vans with single rear wheels go to AUTOS/CAMIONETAS, with double rear wheels to BUS 2 EJES. Use the trash button for anything that is not a vehicle.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if record?.isVideo == true {
                        Text("▶ is the position in the video, when the vehicle's centre entered the box: start the player 1–2 s earlier to see it come in. Tap a photo to enlarge it.")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("The time is when the vehicle's centre entered the box. Tap a photo to enlarge it.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if shown.isEmpty {
                        Text(filter == .category(.sinClasificar) ? "Every truck is classified." : "No detections.")
                            .foregroundColor(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(shown, id: \.trackId) { e in tile(e) }
                    }
                    // why some vehicles have no photo (sample, limit), per class
                    let notes = VehicleClass.allCases.compactMap { c in record?.images?[c.rawValue]?.note(c) }
                    Text((notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n") + "Photos are kept only on this device.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(16)
            }
            .navigationTitle(zoneId.flatMap { id in record?.zones.first(where: { $0.id == id })?.name }
                             ?? (ficha ? "Classify trucks" : "Validate Detections"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $enlarged) { item in
                if let e = Summary.unique((record?.events ?? []).filter { $0.trackId == item.trackId }).first {
                    detail(e)
                }
            }
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

    /// Form column -> class (and axles) stored in the event.
    private func pick(_ e: CountEvent, _ c: FichaCategory) {
        switch c {
        case .autos: model.reclassify(sessionId, trackId: e.trackId, to: .car)
        case .bus: model.reclassify(sessionId, trackId: e.trackId, to: .bus)
        case .motos: model.reclassify(sessionId, trackId: e.trackId, to: .motorcycle)
        case .bicicletas: model.reclassify(sessionId, trackId: e.trackId, to: .bicycle)
        case .c2g: model.reclassify(sessionId, trackId: e.trackId, to: .truck, axle: .c2g)
        case .c34: model.reclassify(sessionId, trackId: e.trackId, to: .truck, axle: .c34)
        case .c5: model.reclassify(sessionId, trackId: e.trackId, to: .truck, axle: .c5)
        case .c6: model.reclassify(sessionId, trackId: e.trackId, to: .truck, axle: .c6)
        case .sinClasificar: model.reclassify(sessionId, trackId: e.trackId, to: .truck)
        }
    }

    private func delete(_ e: CountEvent) {
        if let zoneId {
            model.deleteEvent(sessionId, zoneId: zoneId, trackId: e.trackId)
        } else {
            for z in Set((record?.events ?? []).filter { $0.trackId == e.trackId }.map { $0.zoneId }) {
                model.deleteEvent(sessionId, zoneId: z, trackId: e.trackId)
            }
        }
    }

    /// Video position (bold) and clock time of the moment the vehicle entered the box.
    @ViewBuilder private func times(_ e: CountEvent, large: Bool = false) -> some View {
        let t: (video: String?, clock: String?) = record?.eventTimes(e) ?? (video: nil, clock: nil)
        HStack(spacing: 6) {
            if let video = t.video {
                Text(video).font((large ? Font.title3 : .caption).weight(.bold).monospacedDigit())
            }
            if let clock = t.clock {
                Text(clock).font((large ? Font.body : .caption2).monospacedDigit())
                    .foregroundColor(t.video == nil ? .primary : .secondary)
            }
        }
    }

    /// Class (or E50 form column) picker of a vehicle.
    private func classMenu(_ e: CountEvent) -> some View {
        let category = FichaCategory(e)
        return Menu {
            if ficha {
                ForEach(FichaCategory.allCases.filter { $0 != .sinClasificar }, id: \.self) { c in
                    Button { pick(e, c) } label: { Text((c == category ? "✓ " : "") + c.rawValue) }
                }
            } else {
                ForEach(VehicleClass.allCases, id: \.self) { c in
                    Button { model.reclassify(sessionId, trackId: e.trackId, to: c) } label: {
                        Text((c == e.cls ? "✓ " : "") + c.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                ClassIcon(cls: e.cls, size: 12)
                Text(ficha ? (category?.rawValue ?? e.cls.label) : e.cls.label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ficha && category == .sinClasificar ? Theme.orange : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    /// Enlarged photo, to see the axles of a truck: both times, box, direction and the class picker.
    private func detail(_ e: CountEvent) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let img = model.thumbnail(sessionId, trackId: e.trackId) {
                        Image(uiImage: img).resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Color.gray.opacity(0.15).frame(height: 160).overlay(ClassIcon(cls: e.cls, size: 40))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    times(e, large: true)
                    Text("\(e.zoneName) \(e.direction) · \(e.score.map { "\(Int(($0 * 100).rounded())) % confidence" } ?? "")")
                        .font(.subheadline).foregroundColor(.secondary)
                    classMenu(e).scaleEffect(1.25, anchor: .leading)
                    Button(role: .destructive) {
                        delete(e)
                        enlarged = nil
                    } label: { Label("Not a vehicle: delete", systemImage: "trash") }
                        .padding(.top, 6)
                }
                .padding(16)
            }
            .navigationTitle("Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { enlarged = nil } } }
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
                .contentShape(Rectangle())
                .onTapGesture { enlarged = Enlarged(trackId: e.trackId) }

                Button { delete(e) } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.red, in: Circle())
                }
                .padding(4)
            }
            times(e)
            classMenu(e)
            Text("\(e.score.map { "\(Int(($0 * 100).rounded())) %" } ?? "–") · \(e.zoneName) \(e.direction)")
                .font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
    }
}
