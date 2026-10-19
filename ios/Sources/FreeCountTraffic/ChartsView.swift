import Charts
import SwiftUI
import TrafficCore

/// "Show Graph": vehicles per interval, stacked by class, for all boxes (unique vehicles) or one box,
/// plus the volume table and the peak hour with its peak hour factor.
struct ChartsView: View {
    let record: SessionRecord
    @Environment(\.dismiss) private var dismiss
    @State private var intervalMin = 15
    @State private var zoneId: Int? = nil

    private struct Bar: Identifiable {
        let id = UUID()
        let label: String
        let cls: VehicleClass
        let count: Int
    }

    private var intervalMs: Int64 { Int64(intervalMin) * 60_000 }
    private var rows: [IntervalRow] {
        Summary.intervals(record.events, intervalMs: intervalMs, durationMs: Int64(record.durationMs), zoneId: zoneId)
    }
    private func label(_ ms: Int64) -> String {
        let s = CsvExporter.clock(ms, startEpochMs: record.startEpochMs)
        return String(s.prefix(5)) // hh:mm
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Interval", selection: $intervalMin) {
                        Text("1 min").tag(1)
                        Text("5 min").tag(5)
                        Text("15 min").tag(15)
                        Text("1 hour").tag(60)
                    }
                    .pickerStyle(.segmented)

                    Picker("Box", selection: $zoneId) {
                        Text("All boxes (unique vehicles)").tag(Int?.none)
                        ForEach(record.zones) { z in Text(z.name).tag(Int?.some(z.id)) }
                    }

                    let data = rows
                    let bars = data.flatMap { r in
                        VehicleClass.allCases.compactMap { c in r.byClass[c].map { Bar(label: label(r.startMs), cls: c, count: $0) } }
                    }
                    if bars.isEmpty {
                        Text("No vehicles counted.").foregroundColor(.secondary)
                    } else {
                        Chart(bars) { b in
                            BarMark(x: .value("Start", b.label), y: .value("Vehicles", b.count))
                                .foregroundStyle(by: .value("Class", b.cls.label))
                        }
                        .chartForegroundStyleScale(
                            domain: VehicleClass.allCases.map { $0.label },
                            range: VehicleClass.allCases.map { Theme.cls($0) }
                        )
                        .frame(height: 260)
                    }

                    if let p = Summary.peakHour(record.events, durationMs: Int64(record.durationMs), zoneId: zoneId) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Peak hour").font(.headline)
                            Text("\(label(p.startMs)) – \(label(p.startMs + 3_600_000)): \(p.volume) vehicles")
                            if let phf = p.phf {
                                Text(String(format: "Peak hour factor (PHF): %.2f", phf))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.peach, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(Theme.ink)
                    } else {
                        Text("Peak hour and PHF need at least one hour of counting.").font(.caption).foregroundColor(.secondary)
                    }

                    Text("Volumes").font(.headline)
                    table(data)
                }
                .padding(16)
            }
            .navigationTitle("Graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func table(_ data: [IntervalRow]) -> some View {
        let classes = VehicleClass.allCases.filter { c in data.contains { $0.byClass[c] != nil } }
        return VStack(spacing: 4) {
            HStack {
                Text("Start").frame(width: 56, alignment: .leading)
                ForEach(classes, id: \.self) { c in ClassIcon(cls: c, size: 13).frame(maxWidth: .infinity) }
                Text("Total").frame(width: 44, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            Divider()
            ForEach(Array(data.enumerated()), id: \.offset) { _, r in
                HStack {
                    Text(label(r.startMs)).frame(width: 56, alignment: .leading)
                    ForEach(classes, id: \.self) { c in Text("\(r.byClass[c] ?? 0)").frame(maxWidth: .infinity) }
                    Text("\(r.total)").fontWeight(.semibold).frame(width: 44, alignment: .trailing)
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}
