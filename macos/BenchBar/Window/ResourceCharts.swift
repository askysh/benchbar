import Charts
import SwiftUI

/// The bench page's CPU and memory for the last ten minutes: two small
/// charts, one measure each, with the current value beside them.
///
/// It starts no sampling of its own: the store samples the bench whose
/// Overview the window shows while the window is on screen (the window
/// reports that, not this view: SwiftUI's onDisappear never comes when the
/// window closes, as the window and its views are kept).
struct ResourceSection: View {
    let bench: BenchModel

    var body: some View {
        let history = bench.resources.history
        Section {
            if history.samples.count >= 2, let latest = history.latest {
                let cpu = history.samples.map(\.cpuPercent)
                let memory = history.samples.map { Double($0.memoryBytes) }
                Sparkline(title: "CPU", samples: history.samples, values: cpu, yDomain: ResourceScale.cpu(cpu), fill: true,
                          current: ResourceText.cpu(latest.cpuPercent), format: ResourceText.cpu)
                Sparkline(title: "Memory", samples: history.samples, values: memory, yDomain: ResourceScale.memory(memory), fill: false,
                          current: ResourceText.memory(latest.memoryBytes), format: { ResourceText.memory(UInt64(max(0, $0))) })
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Resources")
        } footer: {
            Text("The bench's own processes (web, workers, Redis, Socket.IO), not the shared MariaDB. Up to the last ten minutes, measured every few seconds while this page is open.")
        }
    }
}

/// One measure over time, no axes: the line shows the shape, the number
/// on the right the value now. Hovering shows the value at that moment.
struct Sparkline: View {
    let title: String
    let samples: [ResourceSample]
    let values: [Double]
    let yDomain: ClosedRange<Double>
    let fill: Bool
    let current: String
    let format: (Double) -> String
    @State private var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hoveredIndex: Int? {
        guard let hovered, !samples.isEmpty else { return nil }
        return samples.indices.min { abs(samples[$0].time.timeIntervalSince(hovered)) < abs(samples[$1].time.timeIntervalSince(hovered)) }
    }

    var body: some View {
        let points = Array(zip(samples.map(\.time), values))
        HStack(spacing: 12) {
            Text(title).frame(width: 64, alignment: .leading)
            Chart {
                ForEach(points, id: \.0) { time, value in
                    if fill {
                        AreaMark(x: .value("Time", time), yStart: .value(title, yDomain.lowerBound), yEnd: .value(title, value))
                            .foregroundStyle(Color.accentColor.opacity(0.12))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Time", time), y: .value(title, value))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let index = hoveredIndex {
                    RuleMark(x: .value("Time", samples[index].time))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", samples[index].time), y: .value(title, values[index]))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(36)
                }
            }
            .chartXScale(domain: ResourceScale.time(samples))
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXSelection(value: $hovered)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .transaction { if reduceMotion { $0.animation = nil } }
            VStack(alignment: .trailing, spacing: 1) {
                Text(hoveredIndex.map { format(values[$0]) } ?? current)
                    .monospacedDigit()
                Text(hoveredIndex.map { samples[$0].time.formatted(date: .omitted, time: .standard) } ?? "now")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(current) now, highest \(format(values.max() ?? 0)) in the chart")
    }
}
