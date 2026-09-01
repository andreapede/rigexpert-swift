import RigXCore
import Charts
import SwiftUI

/// SWR against frequency — the plot an operator actually looks at.
struct SWRChart: View {
    /// Additional traces to compare against, drawn thinner and without markers.
    var others: [(name: String, points: [MeasurementPoint], colorIndex: Int)] = []
    let points: [MeasurementPoint]
    let bestMatch: MeasurementPoint?
    /// Drawn faintly behind, when the reader wants to see what the correction did.
    var rawPoints: [MeasurementPoint] = []
    var cursorFrequency: Double?
    var strings: Strings

    /// One plotted sample.
    ///
    /// `swr` is deliberately the raw value: clamping happens where the sample is drawn,
    /// never here. An earlier version clamped inside this type using the axis ceiling,
    /// while the ceiling was derived from the samples — a mutual recursion that overflowed
    /// the stack on the first point of every sweep.
    private struct Sample: Identifiable {
        /// The index, not a fresh UUID: identity has to be stable across the redraws that
        /// arrive point by point during a live sweep.
        let id: Int
        let megahertz: Double
        /// Absent when |Γ| ≥ 1, which noise near the band edges does produce.
        let swr: Double?
    }

    var body: some View {
        let samples = Self.samples(from: points)
        let raw = Self.samples(from: rawPoints)
        let comparisons = others.map { (name: $0.name, samples: Self.samples(from: $0.points), color: Self.palette($0.colorIndex)) }
        // Both series share the axis, so both have to fit in it.
        let peak = (samples + raw + comparisons.flatMap(\.samples)).compactMap(\.swr).max()
        let ceiling = Self.ceiling(for: peak)
        let span = Self.frequencySpan(samples + raw)

        Chart {
            if ceiling > 2 {
                RuleMark(y: .value("SWR", 2))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("2.0").font(.caption2).foregroundStyle(.secondary)
                    }
            }

            ForEach(raw) { sample in
                LineMark(
                    x: .value(strings.frequency, sample.megahertz),
                    y: .value("SWR", min(sample.swr ?? ceiling, ceiling)),
                    series: .value("Traccia", "grezza")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))
            }

            ForEach(comparisons, id: \.name) { comparison in
                ForEach(comparison.samples) { sample in
                    LineMark(
                        x: .value(strings.frequency, sample.megahertz),
                        y: .value("SWR", min(sample.swr ?? ceiling, ceiling)),
                        series: .value("Traccia", comparison.name)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(comparison.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            }

            ForEach(samples) { sample in
                LineMark(
                    x: .value(strings.frequency, sample.megahertz),
                    y: .value("SWR", min(sample.swr ?? ceiling, ceiling)),
                    series: .value("Traccia", "misura")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.tint)
            }

            if let cursorFrequency {
                RuleMark(x: .value(strings.cursor, cursorFrequency))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }

            if let bestMatch, let swr = bestMatch.reflection().swr {
                PointMark(
                    x: .value(strings.frequency, bestMatch.frequency.megahertz),
                    y: .value("SWR", min(swr, ceiling))
                )
                .symbolSize(70)
                .foregroundStyle(.green)
                .annotation(position: .top) {
                    Text(String(format: "%.3f MHz · %.2f", bestMatch.frequency.megahertz, swr))
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: .rect(cornerRadius: 4))
                }
            }
        }
        .chartYScale(domain: 1...ceiling)
        // Left to itself, Charts rounds the domain outwards and can run the axis below
        // zero — a frequency that does not exist. Pin it to the measurement instead.
        .chartXScale(domain: span)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 9)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.18))
                AxisTick()
                AxisValueLabel {
                    if let megahertz = value.as(Double.self) {
                        Text(Self.frequencyLabel(megahertz, span: span))
                    }
                }
            }
        }
        .chartXAxisLabel("MHz")
        .chartYAxisLabel("SWR")
        .chartYAxis {
            AxisMarks(values: Self.axisValues(upTo: ceiling)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Self.label(number, ceiling: ceiling))
                    }
                }
            }
        }
        .overlay {
            // Only when there is genuinely nothing on the chart. Keyed on the primary
            // trace alone, this covered comparison traces that were drawn perfectly well.
            if points.isEmpty && others.allSatisfy({ $0.points.isEmpty }) {
                ContentUnavailableView(
                    strings.noMeasurement,
                    systemImage: "waveform.path.ecg",
                    description: Text(strings.connectAndSweep)
                )
            }
        }
    }

    /// The exact frequency span of the data, with a hair of margin so the trace does not
    /// sit on the frame. Falls back to a plausible HF range when there is nothing to draw.
    private static func frequencySpan(_ samples: [Sample]) -> ClosedRange<Double> {
        let values = samples.map(\.megahertz)
        guard let low = values.min(), let high = values.max(), high > low else { return 1...30 }
        // Never below zero: a margin subtracted from a sweep starting at 1 MHz puts the
        // axis at -0.69 MHz, and a negative frequency is not a thing.
        let margin = (high - low) * 0.01
        return Swift.max(0, low - margin)...(high + margin)
    }

    /// Enough decimals to tell two ticks apart, and no more: a 1–30 MHz sweep wants whole
    /// numbers, a single-band sweep wants three places.
    private static func frequencyLabel(_ megahertz: Double, span: ClosedRange<Double>) -> String {
        let width = span.upperBound - span.lowerBound
        let decimals = width >= 20 ? 0 : (width >= 2 ? 1 : 3)
        return String(format: "%.\(decimals)f", megahertz)
    }

    /// Distinct hues for the comparison traces; index 0 is the selected one, drawn in
    /// the accent colour by the block above.
    static func palette(_ index: Int) -> Color {
        let colors: [Color] = [.accentColor, .orange, .purple, .teal, .pink, .brown, .indigo]
        return colors[index % colors.count]
    }

    private static func samples(from points: [MeasurementPoint]) -> [Sample] {
        points.enumerated().map { index, point in
            Sample(id: index, megahertz: point.frequency.megahertz, swr: point.reflection().swr)
        }
    }

    /// The smallest ceiling that contains the sweep.
    ///
    /// A fixed 1–10 axis is right for an antenna and useless for a dummy load: a load
    /// swinging between 1.04 and 1.06 draws a dead flat line and the reader concludes the
    /// instrument is not measuring. The axis stays labelled at every scale, so zooming in
    /// never dresses up a negligible variation as a dramatic one.
    private static func ceiling(for peak: Double?) -> Double {
        let candidates: [Double] = [1.1, 1.2, 1.5, 2, 3, 5, Sweep.DisplayLimits.maximumSWR]
        guard let peak else { return 2 }
        return candidates.first { peak <= $0 * 0.98 } ?? Sweep.DisplayLimits.maximumSWR
    }

    private static func axisValues(upTo ceiling: Double) -> [Double] {
        switch ceiling {
        case ...1.2: Array(stride(from: 1.0, through: ceiling + 1e-9, by: 0.05))
        case ...2: Array(stride(from: 1.0, through: ceiling + 1e-9, by: 0.2))
        case ...5: Array(stride(from: 1.0, through: ceiling + 1e-9, by: 0.5))
        default: [1, 1.5, 2, 3, 5, 10]
        }
    }

    private static func label(_ value: Double, ceiling: Double) -> String {
        if value == value.rounded() { return "\(Int(value))" }
        return String(format: ceiling <= 1.2 ? "%.2f" : "%.1f", value)
    }
}
