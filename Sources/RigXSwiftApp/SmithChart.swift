import RigXCore
import SwiftUI

/// The Smith chart, drawn by hand.
///
/// Swift Charts has no notion of it: the grid is not a grid but two families of circles
/// on the reflection-coefficient plane, so it is a `Canvas`. The mathematics is already in
/// `Reflection.smithPoint`; what follows is only geometry.
struct SmithChart: View {
    let points: [MeasurementPoint]
    let referenceImpedance: Double
    let highlighted: MeasurementPoint?
    var cursor: MeasurementPoint?
    /// Canvas has no access to the environment tint, so the trace colour is passed in.
    var traceColor: Color = .accentColor
    /// When a feedline is between the analyzer and the antenna, the trace is rotated by
    /// it, and the upper/lower halves no longer say "too long" and "too short".
    var feedlineDetected: Bool = false
    var strings: Strings

    /// Normalised resistances and reactances to rule.
    private let resistanceGrid: [Double] = [0.2, 0.5, 1, 2, 5]
    private let reactanceGrid: [Double] = [0.2, 0.5, 1, 2, 5]

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 8
            guard radius > 0 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            func place(_ x: Double, _ y: Double) -> CGPoint {
                // The imaginary axis points up on a Smith chart and down on a screen.
                CGPoint(x: center.x + x * radius, y: center.y - y * radius)
            }

            let unitCircle = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
            ))

            let faint = GraphicsContext.Shading.color(.secondary.opacity(0.22))
            let clear = GraphicsContext.Shading.color(.secondary.opacity(0.45))

            context.drawLayer { layer in
                layer.clip(to: unitCircle)

                // Constant resistance: circles centred at r/(1+r) with radius 1/(1+r),
                // all of them touching the open-circuit point at the right.
                for r in resistanceGrid {
                    let ringRadius = radius / (1 + r)
                    let ringCenter = place(r / (1 + r), 0)
                    layer.stroke(
                        Path(ellipseIn: CGRect(
                            x: ringCenter.x - ringRadius, y: ringCenter.y - ringRadius,
                            width: ringRadius * 2, height: ringRadius * 2
                        )),
                        with: r == 1 ? clear : faint,
                        lineWidth: r == 1 ? 1.1 : 0.8
                    )
                }

                // Constant reactance: circles centred at (1, 1/x) with radius 1/|x|,
                // clipped to the unit circle so only the useful arc shows.
                for x in reactanceGrid {
                    for sign in [1.0, -1.0] {
                        let arcRadius = radius / x
                        let arcCenter = place(1, sign / x)
                        layer.stroke(
                            Path(ellipseIn: CGRect(
                                x: arcCenter.x - arcRadius, y: arcCenter.y - arcRadius,
                                width: arcRadius * 2, height: arcRadius * 2
                            )),
                            with: faint,
                            lineWidth: 0.8
                        )
                    }
                }

                var axis = Path()
                axis.move(to: place(-1, 0))
                axis.addLine(to: place(1, 0))
                layer.stroke(axis, with: clear, lineWidth: 0.8)
            }

            context.stroke(unitCircle, with: .color(.secondary.opacity(0.7)), lineWidth: 1.2)

            // Constant-SWR rings. Distance from the centre is the whole point of the
            // chart for a newcomer: how much comes back.
            for (swr, label) in [(1.5, "1.5"), (2.0, "2"), (3.0, "3")] {
                let ringRadius = radius * (swr - 1) / (swr + 1)
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: center.x - ringRadius, y: center.y - ringRadius,
                        width: ringRadius * 2, height: ringRadius * 2
                    )),
                    with: .color(.green.opacity(0.30)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                context.draw(
                    Text(label).font(.system(size: 8)).foregroundStyle(.green.opacity(0.7)),
                    at: CGPoint(x: center.x, y: center.y - ringRadius - 6)
                )
            }

            // The measurement itself.
            var trace = Path()
            var started = false
            for point in points {
                let gamma = point.reflection(referenceImpedance: referenceImpedance).smithPoint
                guard gamma.x.isFinite, gamma.y.isFinite else { continue }
                let position = place(gamma.x, gamma.y)
                if started { trace.addLine(to: position) } else { trace.move(to: position); started = true }
            }
            context.stroke(trace, with: .color(traceColor), lineWidth: 1.6)

            // Where the sweep starts and where it ends, so the trace has a direction.
            let finite = points.filter {
                $0.reflection(referenceImpedance: referenceImpedance).smithPoint.x.isFinite
            }
            if let first = finite.first, let last = finite.last, first.frequency != last.frequency {
                for (point, filled) in [(first, false), (last, true)] {
                    let gamma = point.reflection(referenceImpedance: referenceImpedance).smithPoint
                    let position = place(gamma.x, gamma.y)
                    let box = CGRect(x: position.x - 3.5, y: position.y - 3.5, width: 7, height: 7)
                    if filled {
                        context.fill(Path(ellipseIn: box), with: .color(traceColor))
                    } else {
                        context.stroke(Path(ellipseIn: box), with: .color(traceColor), lineWidth: 1.5)
                    }
                    context.draw(
                        Text(String(format: "%.1f MHz", point.frequency.megahertz))
                            .font(.system(size: 8)).foregroundStyle(.secondary),
                        at: CGPoint(x: position.x, y: position.y - 12)
                    )
                }
            }

            // Labels for someone who has never seen one of these.
            let hint = GraphicsContext.Shading.color(.secondary)
            context.draw(Text(strings.smithShort).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: center.x - radius + 18, y: center.y - 10))
            context.draw(Text(strings.smithOpen).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: center.x + radius - 18, y: center.y - 10))
            context.draw(Text("50 Ω").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: center.x + 16, y: center.y + 9))
            _ = hint

            for (item, color) in [(highlighted, Color.green), (cursor, Color.orange)] {
                guard let item else { continue }
                let gamma = item.reflection(referenceImpedance: referenceImpedance).smithPoint
                let position = place(gamma.x, gamma.y)
                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8)),
                    with: .color(color)
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottom) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    /// What the halves mean — but only when they mean it.
    ///
    /// Above the axis is inductive and below is capacitive, and at an antenna's terminals
    /// that reads directly as too long or too short. Through a feedline it does not: the
    /// line rotates the whole trace, and the same antenna lands in either half depending
    /// on how much cable is in the way. Saying so is the difference between a legend that
    /// teaches and one that misleads.
    private var caption: String {
        // Kept outside the circle rather than drawn on it: inside, this text sat across
        // the constant-SWR ring labels and made them unreadable.
        let tail = feedlineDetected ? strings.smithHalvesRotated : strings.smithHalvesMeaning
        return "\(strings.smithRings)\n\(strings.smithHalves)\(tail)"
    }
}
