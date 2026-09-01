import RigXCore
import Charts
import SwiftUI

/// Resistance and reactance against frequency.
///
/// The plot that tells an operator what to do rather than how bad things are: reactance
/// above zero means the antenna is long, below means short. SWR says only that something
/// is wrong.
struct ImpedanceChart: View {
    let points: [MeasurementPoint]
    var cursorFrequency: Double?
    var strings: Strings
    /// The window shared by every chart, when more than one trace is on screen.
    var frequencyWindow: ClosedRange<Double>?

    private struct Sample: Identifiable {
        let id: Int
        let megahertz: Double
        let value: Double
        let series: String
    }

    var body: some View {
        let limit = Self.limit(for: points)
        let samples = points.enumerated().flatMap { index, point in
            [
                // Not clamped: a clamped value draws a flat plateau at the frame, which
                // reads as measured data. Left alone, Charts clips the line at the edge
                // and the eye correctly sees a curve leaving the plot.
                Sample(id: index * 2, megahertz: point.frequency.megahertz,
                       value: point.impedance.resistance, series: "R"),
                Sample(id: index * 2 + 1, megahertz: point.frequency.megahertz,
                       value: point.impedance.reactance, series: "X"),
            ]
        }

        Chart {
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))

            RuleMark(y: .value("50 Ω", 50))
                .foregroundStyle(.secondary.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(samples) { sample in
                LineMark(
                    x: .value(strings.frequency, sample.megahertz),
                    y: .value("Ω", sample.value),
                    series: .value("Serie", sample.series)
                )
                .foregroundStyle(by: .value("Serie", sample.series))
                .interpolationMethod(.monotone)
            }

            if let cursorFrequency {
                RuleMark(x: .value(strings.cursor, cursorFrequency))
                    .foregroundStyle(.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartForegroundStyleScale(["R": Color.accentColor, "X": Color.purple])
        .chartYScale(domain: -limit...limit)
        .chartXScale(domain: frequencyWindow ?? Self.span(points))
        .chartXAxisLabel("MHz")
        .chartYAxisLabel("Ω")
        .chartLegend(position: .top, alignment: .leading)
        .overlay {
            if points.isEmpty {
                ContentUnavailableView(
                    strings.noMeasurement,
                    systemImage: "waveform.path",
                    description: Text(strings.connectAndSweep)
                )
            }
        }
    }

    /// A robust vertical limit.
    ///
    /// Near an anti-resonance the resistance runs to thousands of ohms; scaling to the
    /// extremes would flatten everything else into the zero line. The ninetieth percentile
    /// keeps the body of the curve readable and lets the spikes clip.
    private static func limit(for points: [MeasurementPoint]) -> Double {
        let magnitudes = points.flatMap { [abs($0.impedance.resistance), abs($0.impedance.reactance)] }
            .filter(\.isFinite)
            .sorted()
        guard let percentile = magnitudes[safe: Int(Double(magnitudes.count) * 0.9)] else { return 100 }
        return max(50, (percentile * 1.15 / 25).rounded(.up) * 25)
    }

    private static func span(_ points: [MeasurementPoint]) -> ClosedRange<Double> {
        let values = points.map(\.frequency.megahertz)
        guard let low = values.min(), let high = values.max(), high > low else { return 1...30 }
        // Never below zero: a margin subtracted from a sweep starting at 1 MHz puts the
        // axis at -0.69 MHz, and a negative frequency is not a thing.
        let margin = (high - low) * 0.01
        return Swift.max(0, low - margin)...(high + margin)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
