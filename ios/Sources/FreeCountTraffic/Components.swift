import SwiftUI
import TrafficCore

struct Swatch: View {
    let color: Color
    var size: CGFloat = 18
    var body: some View {
        RoundedRectangle(cornerRadius: 5).fill(color).frame(width: size, height: size)
    }
}

/// "■ CAR ........ 94" row used inside summary cards.
struct ClassRow: View {
    let cls: VehicleClass
    let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Swatch(color: Theme.cls(cls), size: 14)
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
                        Swatch(color: Theme.cls(c), size: 10)
                        Text("\(n)").font(.subheadline)
                    }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Swatch(color: Theme.zone(index))
                Text(summary.zoneName).font(.headline)
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
            }
            .padding(.leading, 28)
        }
        .padding(.top, 16)
    }
}

/// Total card followed by one section per box.
struct ResultsPanel: View {
    let events: [CountEvent]
    let zones: [Zone]
    var body: some View {
        var byClass: [VehicleClass: Int] = [:]
        for e in events { byClass[e.cls, default: 0] += 1 }
        let summaries = Summary.of(events, zones: zones)
        return VStack(alignment: .leading, spacing: 0) {
            SummaryCard(total: events.count, byClass: byClass)
            ForEach(Array(summaries.enumerated()), id: \.offset) { i, s in ZoneSection(index: i, summary: s) }
        }
    }
}

struct TopBar: View {
    let title: String
    let onBack: () -> Void
    var body: some View {
        HStack {
            Button(action: onBack) { Text("‹ Back").font(.subheadline.weight(.semibold)) }
                .frame(width: 72, alignment: .leading)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Color.clear.frame(width: 72, height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
