import Foundation

/// A frequency, stored canonically in hertz.
///
/// The original AntScope2 codebase passes bare `double` frequencies around in
/// three different units depending on the layer — the analyzer wire protocol
/// speaks megahertz, the device capability table is written in kilohertz, and
/// Touchstone files declare their own unit in the header. Making the unit part
/// of the type removes that whole class of mistake.
public struct Frequency: Sendable, Hashable, Comparable, Codable {
    /// The frequency in hertz.
    public var hertz: Double

    public init(hertz: Double) {
        self.hertz = hertz
    }

    public static func hertz(_ value: Double) -> Frequency { Frequency(hertz: value) }
    public static func kilohertz(_ value: Double) -> Frequency { Frequency(hertz: value * 1_000) }
    public static func megahertz(_ value: Double) -> Frequency { Frequency(hertz: value * 1_000_000) }
    public static func gigahertz(_ value: Double) -> Frequency { Frequency(hertz: value * 1_000_000_000) }

    public var kilohertz: Double { hertz / 1_000 }
    public var megahertz: Double { hertz / 1_000_000 }
    public var gigahertz: Double { hertz / 1_000_000_000 }

    public static func < (lhs: Frequency, rhs: Frequency) -> Bool { lhs.hertz < rhs.hertz }
}

extension Frequency: CustomStringConvertible {
    public var description: String {
        switch abs(hertz) {
        case 1_000_000_000...: String(format: "%.6g GHz", gigahertz)
        case 1_000_000...: String(format: "%.6g MHz", megahertz)
        case 1_000...: String(format: "%.6g kHz", kilohertz)
        default: String(format: "%.6g Hz", hertz)
        }
    }
}
