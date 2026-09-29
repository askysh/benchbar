import Charts
import SwiftUI

/// The bench page's CPU and memory for the last ten minutes: two small
/// charts, one measure each, with the current value beside them.
struct ResourceSection: View {
    let bench: BenchModel

    var body: some View {
        let history = bench.resources.history
        Section {
            if let latest = history.latest {
                Sparkline(title: "CPU", samples: history.samples, value: \.cpuPercent,
                          current: ResourceText.cpu(latest.cpuPercent), format: ResourceText.cpu)
                Sparkline(title: "Memory", samples: history.samples, value: { Double($0.memoryBytes) },
                          current: ResourceText.memory(latest.memoryBytes), format: { ResourceText.memory(UInt64(max(0, $0))) })
            } else {
                Text("Measuring…").foregroundStyle(.secondary)
            }
        } header: {
            Text("Resources")
        } footer: {
            Text("The bench's own processes (web, workers, Redis, Socket.IO), not the shared MariaDB. Last ten minutes, measured while BenchBar refreshes the bench.")
        }
    }
}

/// One measure over time, no axes: the line shows the shape, the number
/// on the right the value now. Hovering shows the value at that moment.
struct Sparkline: View {
    let title: String
    let samples: [ResourceSample]
    let value: (ResourceSample) -> Double
    let current: String
    let format: (Double) -> String
    @State private var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, samples: [ResourceSample], value: @escaping (ResourceSample) -> Double,
         current: String, format: @escaping (Double) -> String) {
        self.title = title
        self.samples = samples
        self.value = value
        self.current = current
        self.format = format
    }

    init(title: String, samples: [ResourceSample], value: KeyPath<ResourceSample, Double>,
         current: String, format: @escaping (Double) -> String) {
        self.init(title: title, samples: samples, value: { $0[keyPath: value] }, current: current, format: format)
    }

    private var hoveredSample: ResourceSample? {
        guard let hovered else { return nil }
        return samples.min { abs($0.time.timeIntervalSince(hovered)) < abs($1.time.timeIntervalSince(hovered)) }
    }

    var body: some View {
        let end = samples.last?.time ?? .now
        let peak = samples.map(value).max() ?? 0
        HStack(spacing: 12) {
            Text(title).frame(width: 60, alignment: .leading)
            Chart {
                ForEach(samples, id: \.time) { sample in
                    AreaMark(x: .value("Time", sample.time), y: .value(title, value(sample)))
                        .foregroundStyle(Color.accentColor.opacity(0.12))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.time), y: .value(title, value(sample)))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let sample = hoveredSample {
                    RuleMark(x: .value("Time", sample.time))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", sample.time), y: .value(title, value(sample)))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(40)
                }
            }
            .chartXScale(domain: end.addingTimeInterval(-ResourceHistory.window)...end)
            // a flat idle line sits on the floor instead of filling the chart
            .chartYScale(domain: 0...max(peak * 1.15, 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXSelection(value: $hovered)
            .frame(height: 32)
            .transaction { if reduceMotion { $0.animation = nil } }
            Text(hoveredSample.map { "\(format(value($0))) at \($0.time.formatted(date: .omitted, time: .shortened))" } ?? current)
                .monospacedDigit()
                .foregroundStyle(hoveredSample == nil ? .primary : .secondary)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(current) now, highest \(format(peak)) in the last ten minutes")
    }
}
