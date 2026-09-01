import Foundation

/// One measured frequency point: what the analyzer actually reports.
///
/// The wire protocol sends exactly this triple — frequency, R, X — as a comma
/// separated line; everything else the application displays is derived.
public struct MeasurementPoint: Sendable, Hashable, Codable {
    public var frequency: Frequency
    public var impedance: Impedance

    public init(frequency: Frequency, impedance: Impedance) {
        self.frequency = frequency
        self.impedance = impedance
    }

    public func reflection(referenceImpedance z0: Double = .standardZ0) -> Reflection {
        Reflection(impedance: impedance, referenceImpedance: z0)
    }
}

/// A complete frequency sweep, plus the metadata needed to redraw and export it.
public struct Sweep: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var date: Date
    /// The system impedance the measurement is referred to. Almost always 50 Ω.
    public var referenceImpedance: Double
    public var points: [MeasurementPoint]

    public init(
        id: UUID = UUID(),
        name: String,
        date: Date = Date(),
        referenceImpedance: Double = .standardZ0,
        points: [MeasurementPoint] = []
    ) {
        self.id = id
        self.name = name
        self.date = date
        self.referenceImpedance = referenceImpedance
        self.points = points
    }

    public var frequencyRange: ClosedRange<Frequency>? {
        guard let first = points.first?.frequency else { return nil }
        return points.dropFirst().reduce(first...first) { range, point in
            min(range.lowerBound, point.frequency)...max(range.upperBound, point.frequency)
        }
    }

    /// Γ at every point, referred to this sweep's system impedance.
    public var reflections: [Reflection] {
        points.map { $0.reflection(referenceImpedance: referenceImpedance) }
    }

    /// The point whose SWR is lowest — the resonance the operator is usually hunting for.
    public var bestMatch: MeasurementPoint? {
        points.min { lhs, rhs in
            let l = lhs.reflection(referenceImpedance: referenceImpedance).magnitude
            let r = rhs.reflection(referenceImpedance: referenceImpedance).magnitude
            return l < r
        }
    }
}

extension Sweep {
    /// Display clamps matching AntScope2's plotting behaviour.
    ///
    /// The original caps SWR at 200 in the data layer and again at 10 for the visible
    /// plot range, and floors it at 1. Kept here so a port can be compared against the
    /// shipping application pixel for pixel, rather than baked into `Reflection.swr`.
    public enum DisplayLimits {
        public static let maximumSWR: Double = 10
        public static let maximumStoredSWR: Double = 200

        public static func clampSWR(_ swr: Double?, to limit: Double = maximumStoredSWR) -> Double {
            guard let swr else { return limit }
            return Swift.min(Swift.max(swr, 1), limit)
        }
    }
}
