import SwiftUI
import TrafficCore

struct Swatch: View {
    let color: Color
    var size: CGFloat = 18
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1.5))
            .frame(width: size, height: size)
    }
}

/// "■ CAR ........ 94" row used inside summary cards.
struct ClassRow: View {
    let cls: VehicleClass
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            ClassIcon(cls: cls, size: 15)
            Text(cls.label.uppercased()).font(.subheadline)
            Spacer()
            Text("\(count)").font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

/// Compact "■ 94  ■ 3" chips for the live per-box list.
struct ClassChips: View {
    let byClass: [VehicleClass: Int]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(VehicleClass.allCases, id: \.self) { c in
                if let n = byClass[c] {
                    HStack(spacing: 4) {
                        ClassIcon(cls: c, size: 16)
                        Text("\(n)").font(.subheadline.monospacedDigit()).lineLimit(1)
                    }
                    .fixedSize()
                }
            }
        }
    }
}

struct SummaryCard: View {
    let total: Int
    let byClass: [VehicleClass: Int]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Total Unique Vehicles Tracked").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(total)").font(.title.weight(.bold))
            }
            ForEach(VehicleClass.allCases, id: \.self) { c in
                if let n = byClass[c] { ClassRow(cls: c, count: n) }
            }
        }
        .foregroundColor(Theme.ink)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.peach, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ZoneSection: View {
    let index: Int
    let summary: ZoneSummary
    var filter: Heading?
    var onValidate: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Swatch(color: Theme.zone(index))
                Text(summary.zoneName).font(.headline)
                if let filter { Text("only \(filter.arrow)").font(.caption).foregroundColor(.secondary) }
                Spacer()
                Text("\(summary.total) vehicles").font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(VehicleClass.allCases, id: \.self) { c in
                    if let n = summary.byClass[c] { ClassRow(cls: c, count: n) }
                }
                if !summary.byDirection.isEmpty {
                    Text("Direction: " + summary.byDirection.keys.sorted().map { "\($0) \(summary.byDirection[$0] ?? 0)" }.joined(separator: "   "))
                        .font(.caption)
                        .padding(.top, 4)
                }
                if let avg = summary.avgSpeedKmh {
                    Text(String(format: "Speed: avg %.0f km/h · max %.0f km/h", avg, summary.maxSpeedKmh ?? 0))
                        .font(.caption.weight(.medium))
                }
                if let onValidate, summary.total > 0 {
                    Button(action: onValidate) {
                        Label("Validate Detections", systemImage: "checkmark.rectangle.stack")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
            .padding(.leading, 28)
        }
        .padding(.top, 16)
    }
}

/// Total card (unique vehicles: one crossing two boxes counts once) followed by one section per box.
struct ResultsPanel: View {
    let events: [CountEvent]
    let zones: [Zone]
    var onValidate: ((Int) -> Void)?
    var body: some View {
        let unique = Summary.unique(events)
        let summaries = Summary.of(events, zones: zones)
        return VStack(alignment: .leading, spacing: 0) {
            SummaryCard(total: unique.count, byClass: Summary.byClass(unique))
            ForEach(Array(summaries.enumerated()), id: \.offset) { i, s in
                ZoneSection(index: i, summary: s,
                            filter: zones.first(where: { $0.id == s.zoneId })?.direction,
                            onValidate: onValidate.map { cb -> () -> Void in { cb(s.zoneId) } })
            }
        }
    }
}

/// "All directions" + the 8 arrows, for the per-box direction filter.
struct DirectionMenu: View {
    let current: Heading?
    let onPick: (Heading?) -> Void
    var body: some View {
        Menu {
            Button { onPick(nil) } label: { Label("All directions", systemImage: current == nil ? "checkmark" : "arrow.up.and.down.and.arrow.left.and.right") }
            ForEach(Heading.allCases, id: \.self) { h in
                Button { onPick(h) } label: { Text((current == h ? "✓ " : "") + "Only \(h.arrow)") }
            }
        } label: {
            Group {
                if let current { Text(current.arrow).font(.system(size: 18, weight: .bold)) }
                else { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 15)) }
            }
            .foregroundColor(Theme.orange)
            .frame(width: 30, height: 30)
        }
    }
}

struct TopBar: View {
    let title: String
    let onBack: () -> Void
    var trailing: AnyView?
    var body: some View {
        HStack {
            Button(action: onBack) { Text("‹ Back").font(.subheadline.weight(.semibold)) }
                .frame(width: 72, alignment: .leading)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            HStack {
                Spacer()
                trailing
            }
            .frame(width: 72, height: 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
