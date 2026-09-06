import RigXCore
import Charts
import SwiftUI

/// The lines where one kind of operating gives way to the next.
///
/// Chart content rather than an overlay, so the rules take the plot's own height without
/// this having to know what it is.
struct BandSegmentDividers: ChartContent {
    let band: AmateurBand?
    let span: ClosedRange<Double>

    var body: some ChartContent {
        ForEach(band.map { BandLabelLayout.dividers(for: $0, in: span) } ?? [], id: \.self) { megahertz in
            RuleMark(x: .value("MHz", megahertz))
                // Faint enough not to compete with the trace, solid enough to be seen
                // through the band's own green shading, which a third of an opacity was
                // not: on screen the rules had all but disappeared into it.
                .foregroundStyle(.secondary.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }
}

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
                        id: \.id
                    ) { placement in
                        Text(placement.text)
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
    /// Something with a name and a stretch of frequency, in MHz. A band or one of its
    /// mode segments: the layout is the same problem either way.
    struct Item {
        let id: String
        let text: String
        let span: ClosedRange<Double>
    }

    struct Placement {
        let id: String
        let text: String
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

    /// The frequencies where one kind of operating gives way to the next, in MHz.
    ///
    /// Drawn as dashed rules the full height of the plot: the strip alone answers "what
    /// is at the bottom of the chart here", and a reader following the trace at SWR 3
    /// has to drop their eye to the foot and back to place it. The rules carry the
    /// division up to where the curve actually is.
    static func dividers(for band: AmateurBand, in span: ClosedRange<Double>) -> [Double] {
        let edges = band.segments.flatMap {
            [$0.range.lowerBound.megahertz, $0.range.upperBound.megahertz]
        }
        // A rule sitting on the frame is a thicker frame, not information.
        let margin = (span.upperBound - span.lowerBound) * 0.005
        let inside = edges.filter {
            $0 > span.lowerBound + margin && $0 < span.upperBound - margin
        }
        // Adjacent segments share an edge, and it is one line, not two.
        var seen: Set<Double> = []
        return inside.filter { seen.insert($0).inserted }.sorted()
    }

    static func placements(
        for bands: [AmateurBand], span: ClosedRange<Double>, width: Double
    ) -> [Placement] {
        place(bands.map { Item(id: $0.id, text: $0.name, span: $0.range.megahertz) },
              span: span, width: width)
    }

    static func place(_ items: [Item], span: ClosedRange<Double>, width: Double) -> [Placement] {
        let range = span.upperBound - span.lowerBound
        guard width > 0, range > 0 else { return [] }

        /// The part of the item that is on screen: one running off the edge gets its name
        /// over the half the reader can see, not over its true centre off-chart.
        func visible(_ item: Item) -> ClosedRange<Double>? {
            let low = max(item.span.lowerBound, span.lowerBound)
            let high = min(item.span.upperBound, span.upperBound)
            return high >= low ? low...high : nil
        }

        func position(_ megahertz: Double) -> Double {
            (megahertz - span.lowerBound) / range * width
        }

        let candidates = items.compactMap { item -> (item: Item, visible: ClosedRange<Double>)? in
            visible(item).map { (item, $0) }
        }
        // Widest first, and the tie broken by frequency so the result never depends on
        // the order the caller happened to build the list in.
        .sorted {
            let left = $0.visible.upperBound - $0.visible.lowerBound
            let right = $1.visible.upperBound - $1.visible.lowerBound
            if left != right { return left > right }
            return $0.item.span.lowerBound < $1.item.span.lowerBound
        }

        var taken: [ClosedRange<Double>] = []
        var placed: [(Placement, Double)] = []
        for candidate in candidates {
            // Nominal, not measured: laying out text to place a 4-character label would
            // cost a text run per item per redraw, and the estimate only has to be close
            // enough to keep two names apart.
            let labelWidth = Double(candidate.item.text.count) * 5.5 + 6
            guard labelWidth <= width else { continue }

            let centre = (candidate.visible.lowerBound + candidate.visible.upperBound) / 2
            // Nudged inside the plot rather than dropped: an item at the very edge of the
            // sweep is exactly the one whose name the reader wants.
            let x = min(max(position(centre), labelWidth / 2), width - labelWidth / 2)
            let interval = (x - labelWidth / 2)...(x + labelWidth / 2)
            guard !taken.contains(where: { $0.overlaps(interval) }) else { continue }
            taken.append(interval)
            placed.append(
                (Placement(id: candidate.item.id, text: candidate.item.text, x: x),
                 candidate.item.span.lowerBound)
            )
        }
        return placed.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

extension View {
    /// Draws the band's mode segments as a strip along the foot of the plot.
    ///
    /// A strip, not a full-height shading: the plot already carries the band in green,
    /// and four more coloured columns behind the trace would be a stained-glass window.
    /// At the foot it reads the way a band plan is drawn on paper — a ruler under the
    /// spectrum — and it is translucent, so the trace crossing it stays visible.
    func bandSegments(_ band: AmateurBand?, span: ClosedRange<Double>, strings: Strings) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                if let band, let plot = proxy.plotFrame {
                    BandSegmentStrip(band: band, span: span, strings: strings, frame: geometry[plot])
                }
            }
        }
    }
}

struct BandSegmentStrip: View {
    let band: AmateurBand
    let span: ClosedRange<Double>
    let strings: Strings
    let frame: CGRect

    private let height: CGFloat = 15

    /// One colour per kind of operating, and the same colours in the legend beside the
    /// chart. Not the trace's own blue and purple, which mean R and X two inches above.
    static func colour(_ mode: BandSegment.Mode) -> Color {
        switch mode {
        case .cw: .cyan
        case .digital: .orange
        // Light green, and a lighter one than the band shading it sits on, which is a
        // flat dark green at a sixth opacity.
        case .phone: Color(red: 0.55, green: 0.90, blue: 0.50)
        case .beacon: .red
        case .satellite: .indigo
        }
    }

    var body: some View {
        let visible = band.segments.compactMap { segment -> (segment: BandSegment, span: ClosedRange<Double>)? in
            let low = Swift.max(segment.range.lowerBound.megahertz, span.lowerBound)
            let high = Swift.min(segment.range.upperBound.megahertz, span.upperBound)
            return high > low ? (segment, low...high) : nil
        }
        let y = frame.maxY - height / 2 - 1
        let labels = BandLabelLayout.place(
            visible.map {
                BandLabelLayout.Item(id: $0.segment.id, text: strings.mode($0.segment.mode), span: $0.span)
            },
            span: span,
            width: frame.width
        )

        ZStack(alignment: .topLeading) {
            ForEach(visible, id: \.segment.id) { entry in
                let start = position(entry.span.lowerBound)
                let end = position(entry.span.upperBound)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.colour(entry.segment.mode).opacity(0.45))
                    .frame(width: Swift.max(1, end - start), height: height)
                    .position(x: (start + end) / 2, y: y)
            }
            ForEach(labels, id: \.id) { label in
                Text(label.text)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .position(x: frame.minX + label.x, y: y)
            }
        }
    }

    private func position(_ megahertz: Double) -> CGFloat {
        let width = span.upperBound - span.lowerBound
        guard width > 0 else { return frame.minX }
        return frame.minX + CGFloat((megahertz - span.lowerBound) / width) * frame.width
    }
}
