import Charts
import RigXCore
import SwiftUI

/// Impedance along the cable, instead of against frequency.
///
/// The plot is drawn no finer than the bandwidth earns: a peak shown at 1.72 m with a
/// resolution of 0.95 m means "somewhere between 1.25 and 2.20", and the chart says so
/// rather than letting a sharp line imply otherwise.
struct TDRChart: View {
    let response: TimeDomainResponse?
    var strings: Strings

    private struct Sample: Identifiable {
        let id: Int
        let distance: Double
        let impedance: Double
    }

    var body: some View {
        Group {
            if let response {
                chart(response)
            } else {
                ContentUnavailableView(
                    strings.noMeasurement,
                    systemImage: "ruler",
                    description: Text(strings.tdrNeedsUniformSweep)
                )
            }
        }
    }

    private func chart(_ response: TimeDomainResponse) -> some View {
        // Far beyond the strongest feature there is nothing but noise; showing 300 m of
        // it would hide the metre that matters.
        let peak = response.dominantDiscontinuity
        let limit = min(
            response.unambiguousRange,
            max(4, (peak?.distance ?? 2) * 3)
        )
        let samples = zip(response.distances, response.impedance).enumerated()
            .filter { $0.element.0 <= limit }
            .map { Sample(id: $0.offset, distance: $0.element.0, impedance: $0.element.1) }
        let ceiling = max(120, (samples.map(\.impedance).max() ?? 100) * 1.1)

        return VStack(spacing: 6) {
            Chart {
                RuleMark(y: .value("Z0", response.referenceImpedance))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(samples) { sample in
                    LineMark(
                        x: .value(strings.distance, sample.distance),
                        y: .value("Ω", min(sample.impedance, ceiling))
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.tint)
                }

                if let peak, peak.distance <= limit {
                    // The resolution drawn as a band, not a line: it is the honest width
                    // of the answer.
                    RectangleMark(
                        xStart: .value("", peak.distance - response.resolution / 2),
                        xEnd: .value("", peak.distance + response.resolution / 2),
                        yStart: .value("", 0),
                        yEnd: .value("", ceiling)
                    )
                    .foregroundStyle(.green.opacity(0.12))

                    RuleMark(x: .value(strings.distance, peak.distance))
                        .foregroundStyle(.green.opacity(0.8))
                        .annotation(position: .top) {
                            Text(String(format: "%.2f m  ± %.2f", peak.distance, response.resolution / 2))
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.15), in: .rect(cornerRadius: 4))
                        }
                }
            }
            .chartXScale(domain: 0...limit)
            .chartYScale(domain: 0...ceiling)
            .chartXAxisLabel(strings.metres)
            .chartYAxisLabel("Ω")

            Text(strings.tdrCaption(
                resolution: response.resolution,
                window: response.window.name,
                velocityFactor: response.velocityFactor
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
