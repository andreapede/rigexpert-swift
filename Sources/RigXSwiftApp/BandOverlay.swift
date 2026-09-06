import RigXCore
import Charts
import SwiftUI

/// The amateur bands, shaded behind a frequency chart.
///
/// Shading rather than lines at the edges: the question the overlay answers is "is the
/// dip inside a band", and a filled region answers it at a glance where two rules would
/// leave the reader measuring by eye.
struct BandShading: ChartContent {
    let bands: [AmateurBand]
    /// The chart's own x domain, in MHz. Narrow bands are widened to stay visible in it.
    let span: ClosedRange<Double>

    var body: some ChartContent {
        ForEach(bands) { band in
            let drawn = BandLabelLayout.drawnRange(for: band, in: span)
            RectangleMark(
                xStart: .value("MHz", drawn.lowerBound),
                xEnd: .value("MHz", drawn.upperBound)
            )
            // Conditional bands fainter: an antenna can cover 4 m without its owner
            // being licensed for it. Only a little fainter, though — 4 m is 200 kHz
            // wide and conditional in Italy, and it was disappearing altogether on a
            // sweep that ran to 170 MHz.
            .foregroundStyle(.green.opacity(band.isConditional ? 0.11 : 0.16))
        }
    }
}

extension View {
    /// Names the bands along the top of the chart, as many as fit.
    func bandNames(_ bands: [AmateurBand], span: ClosedRange<Double>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    ForEach(
                        BandLabelLayout.placements(for: bands, span: span, width: frame.width),
                        id: \.band.id
                    ) { placement in
                        Text(placement.band.name)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .position(x: frame.minX + placement.x, y: frame.minY + 7)
                    }
                }
            }
        }
    }
}

/// Where the band names go.
///
/// Over 1–170 MHz the HF bands are a few pixels wide and their names are not: 30 m, 17 m
/// and 12 m collide into an unreadable smear if every band is labelled unconditionally.
/// The rule is that a name is drawn only where it does not touch one already drawn, and
/// that the widest bands are considered first — so what survives at a coarse zoom is the
/// spectrum the operator is most likely working in, not whichever band happens to be
/// leftmost.
enum BandLabelLayout {
    struct Placement {
        let band: AmateurBand
        /// Centre of the label, in points from the left edge of the plot area.
        let x: Double
    }

    /// A band as it should be drawn: at least a thin sliver, so that 30 m over a 170 MHz
    /// sweep is still something the eye can find rather than a zero-width rectangle.
    static func drawnRange(for band: AmateurBand, in span: ClosedRange<Double>) -> ClosedRange<Double> {
        let low = band.range.lowerBound.megahertz
        let high = band.range.upperBound.megahertz
        // Four thousandths of the width: about five points on a full-screen chart,
        // which is thin and still findable.
        let floor = (span.upperBound - span.lowerBound) * 0.004
        guard high - low < floor else { return low...high }
        let centre = (low + high) / 2
        return (centre - floor / 2)...(centre + floor / 2)
    }

    static func placements(
        for bands: [AmateurBand], span: ClosedRange<Double>, width: Double
    ) -> [Placement] {
        let range = span.upperBound - span.lowerBound
        guard width > 0, range > 0 else { return [] }

        /// The part of the band that is on screen: a band running off the edge gets its
        /// name over the half the reader can see, not over its true centre off-chart.
        func visible(_ band: AmateurBand) -> ClosedRange<Double>? {
            let low = max(band.range.lowerBound.megahertz, span.lowerBound)
            let high = min(band.range.upperBound.megahertz, span.upperBound)
            return high >= low ? low...high : nil
        }

        func position(_ megahertz: Double) -> Double {
            (megahertz - span.lowerBound) / range * width
        }

        let candidates = bands.compactMap { band -> (band: AmateurBand, visible: ClosedRange<Double>)? in
            visible(band).map { (band, $0) }
        }
        // Widest first, and the tie broken by frequency so the result never depends on
        // the order the caller happened to build the list in.
        .sorted {
            let left = $0.visible.upperBound - $0.visible.lowerBound
            let right = $1.visible.upperBound - $1.visible.lowerBound
            if left != right { return left > right }
            return $0.band.range.lowerBound < $1.band.range.lowerBound
        }

        var taken: [ClosedRange<Double>] = []
        var placed: [Placement] = []
        for candidate in candidates {
            // Nominal, not measured: laying out text to place a 4-character label would
            // cost a text run per band per redraw, and the estimate only has to be close
            // enough to keep two names apart.
            let labelWidth = Double(candidate.band.name.count) * 5.5 + 6
            guard labelWidth <= width else { continue }

            let centre = (candidate.visible.lowerBound + candidate.visible.upperBound) / 2
            // Nudged inside the plot rather than dropped: a band at the very edge of the
            // sweep is exactly the one whose name the reader wants.
            let x = min(max(position(centre), labelWidth / 2), width - labelWidth / 2)
            let interval = (x - labelWidth / 2)...(x + labelWidth / 2)
            guard !taken.contains(where: { $0.overlaps(interval) }) else { continue }
            taken.append(interval)
            placed.append(Placement(band: candidate.band, x: x))
        }
        return placed.sorted { $0.band.range.lowerBound < $1.band.range.lowerBound }
    }
}
