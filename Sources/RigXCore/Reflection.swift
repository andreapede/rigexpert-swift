import Foundation

/// The complex reflection coefficient Γ, referred to a system impedance Z₀.
///
/// Every scalar the application plots — SWR, return loss, ρ, phase, the Smith
/// trace — is a function of Γ alone, so the whole derived-parameter surface
/// hangs off this one type.
public struct Reflection: Sendable, Hashable, Codable {
    public var real: Double
    public var imaginary: Double

    public init(real: Double, imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }

    /// Γ for an impedance referred to `referenceImpedance`.
    ///
    /// `Γ = (Z - Z₀) / (Z + Z₀)`, expanded to avoid complex division:
    /// `Re = (R² - Z₀² + X²) / ((R + Z₀)² + X²)`, `Im = 2·Z₀·X / ((R + Z₀)² + X²)`.
    public init(impedance: Impedance, referenceImpedance z0: Double = .standardZ0) {
        let r = impedance.resistance
        let x = impedance.reactance
        let denominator = (r + z0) * (r + z0) + x * x
        guard denominator != 0 else {
            self.init(real: 0, imaginary: 0)
            return
        }
        self.init(
            real: (r * r - z0 * z0 + x * x) / denominator,
            imaginary: (2 * z0 * x) / denominator
        )
    }

    /// |Γ|, also called ρ (rho).
    public var magnitude: Double {
        (real * real + imaginary * imaginary).squareRoot()
    }

    /// The phase of Γ in degrees, in `(-180, 180]`.
    public var phaseDegrees: Double {
        atan2(imaginary, real) / .pi * 180
    }

    /// Voltage standing wave ratio, `(1 + |Γ|) / (1 - |Γ|)`.
    ///
    /// `nil` when |Γ| ≥ 1, which is not physically meaningful for a passive load
    /// but does occur on noisy measurements near the ends of a sweep.
    public var swr: Double? {
        let rho = magnitude
        guard rho < 1 else { return nil }
        return (1 + rho) / (1 - rho)
    }

    /// Return loss in dB, `-20·log₁₀|Γ|`. Infinite for a perfect match.
    public var returnLossDecibels: Double {
        let rho = magnitude
        guard rho > 0 else { return .infinity }
        return -20 * log10(rho)
    }

    /// The impedance that produces this Γ, referred to `referenceImpedance`.
    public func impedance(referenceImpedance z0: Double = .standardZ0) -> Impedance {
        let denominator = (1 - real) * (1 - real) + imaginary * imaginary
        guard denominator != 0 else {
            return Impedance(resistance: .infinity, reactance: .infinity)
        }
        return Impedance(
            resistance: z0 * (1 - real * real - imaginary * imaginary) / denominator,
            reactance: z0 * (2 * imaginary) / denominator
        )
    }

    /// The point on a unit-radius Smith chart. The view layer scales it to the plot radius.
    public var smithPoint: SmithPoint {
        SmithPoint(x: real, y: imaginary)
    }

    /// Clamps Γ just inside the unit circle, as AntScope2 does after applying an
    /// OSL correction that pushed the point to or past |Γ| = 1.
    public func clampedInsideUnitCircle(limit: Double = 0.999_999_992) -> Reflection {
        let rho = magnitude
        guard rho >= 1 else { return self }
        guard rho > 0 else { return Reflection(real: limit, imaginary: 0) }
        return Reflection(real: limit * real / rho, imaginary: limit * imaginary / rho)
    }
}

/// A point in the Smith chart plane, on a unit-radius circle.
public struct SmithPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

extension Double {
    /// The 50 Ω system impedance assumed throughout amateur and commercial RF practice.
    public static let standardZ0: Double = 50
}
