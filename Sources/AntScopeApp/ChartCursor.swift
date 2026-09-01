import Charts
import SwiftUI

/// Turns a chart into something you can read a value off, by hovering.
///
/// The plot area is not the view's bounds — axes and labels take space — so the pointer
/// has to be translated into the plot's own coordinates before Charts can map it back to
/// a frequency.
struct ChartCursor: ViewModifier {
    @Binding var frequency: Double?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else {
                                frequency = nil
                                return
                            }
                            let origin = geometry[plot].origin
                            frequency = proxy.value(atX: location.x - origin.x, as: Double.self)
                        case .ended:
                            frequency = nil
                        }
                    }
            }
        }
    }
}

extension View {
    func chartCursor(frequency: Binding<Double?>) -> some View {
        modifier(ChartCursor(frequency: frequency))
    }
}
