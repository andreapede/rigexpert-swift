import Foundation

/// A complex impedance `R + jX`, in ohms.
public struct Impedance: Sendable, Hashable, Codable {
    /// Series resistance R, in ohms.
    public var resistance: Double
    /// Series reactance X, in ohms.
    public var reactance: Double

    public init(resistance: Double, reactance: Double) {
        self.resistance = resistance
        self.reactance = reactance
    }

    /// |Z| = sqrt(R² + X²).
    public var magnitude: Double {
        (resistance * resistance + reactance * reactance).squareRoot()
    }

    /// The equivalent parallel circuit: `Rp = (R²+X²)/R`, `Xp = (R²+X²)/X`.
    ///
    /// - Note: AntScope2 computes this correctly on the raw measurement but uses the
    ///   *series* reactance as `Xp` on the calibration-corrected path
    ///   (`measurements.cpp`, `rpxGraphCalib`), so its parallel-X plot is wrong whenever
    ///   calibration is enabled. This implementation is correct in both cases.
    public var parallelEquivalent: Impedance {
        let sum = resistance * resistance + reactance * reactance
        return Impedance(
            resistance: resistance == 0 ? .infinity : sum / resistance,
            reactance: reactance == 0 ? .infinity : sum / reactance
        )
    }
}
