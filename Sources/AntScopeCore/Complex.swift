import Foundation

/// A complex number.
///
/// Small on purpose: just enough to write the calibration algebra as algebra. The original
/// expands the same arithmetic by hand into sixty lines of paired `double`s, where a
/// transposed sign is invisible.
public struct Complex: Sendable, Hashable, Codable {
    public var real: Double
    public var imaginary: Double

    public init(_ real: Double, _ imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }

    public static let zero = Complex(0, 0)
    public static let one = Complex(1, 0)

    public var magnitude: Double { (real * real + imaginary * imaginary).squareRoot() }
    public var squaredMagnitude: Double { real * real + imaginary * imaginary }
    public var conjugate: Complex { Complex(real, -imaginary) }

    public static func + (a: Complex, b: Complex) -> Complex {
        Complex(a.real + b.real, a.imaginary + b.imaginary)
    }

    public static func - (a: Complex, b: Complex) -> Complex {
        Complex(a.real - b.real, a.imaginary - b.imaginary)
    }

    public static func * (a: Complex, b: Complex) -> Complex {
        Complex(
            a.real * b.real - a.imaginary * b.imaginary,
            a.real * b.imaginary + a.imaginary * b.real
        )
    }

    public static func / (a: Complex, b: Complex) -> Complex {
        let denominator = b.squaredMagnitude
        guard denominator != 0 else { return Complex(.nan, .nan) }
        let numerator = a * b.conjugate
        return Complex(numerator.real / denominator, numerator.imaginary / denominator)
    }

    public static func * (a: Complex, b: Double) -> Complex { Complex(a.real * b, a.imaginary * b) }
    public static func / (a: Complex, b: Double) -> Complex { Complex(a.real / b, a.imaginary / b) }

    /// `e^(i·angle)`, the unit vector at that angle in radians.
    public static func unit(angle: Double) -> Complex { Complex(cos(angle), sin(angle)) }

    /// Linear interpolation, `self` at 0 and `other` at 1.
    public func interpolated(to other: Complex, at fraction: Double) -> Complex {
        Complex(
            real + (other.real - real) * fraction,
            imaginary + (other.imaginary - imaginary) * fraction
        )
    }
}

extension Reflection {
    public var complex: Complex { Complex(real, imaginary) }

    public init(_ value: Complex) {
        self.init(real: value.real, imaginary: value.imaginary)
    }
}
