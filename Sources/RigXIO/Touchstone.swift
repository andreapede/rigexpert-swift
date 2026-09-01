import RigXCore
import Foundation

/// A one-port Touchstone (`.s1p`) file: what AntScope2 reads and writes for both
/// calibration standards and exported measurements.
public struct TouchstoneFile: Sendable, Hashable {
    /// The system impedance declared in the option line, in ohms.
    public var referenceImpedance: Double
    public var points: [MeasurementPoint]

    public init(points: [MeasurementPoint], referenceImpedance: Double = .standardZ0) {
        self.points = points
        self.referenceImpedance = referenceImpedance
    }

    /// The frequency unit declared in a Touchstone option line.
    public enum FrequencyUnit: String, Sendable, CaseIterable {
        case hertz = "HZ"
        case kilohertz = "KHZ"
        case megahertz = "MHZ"
        case gigahertz = "GHZ"

        func frequency(_ value: Double) -> Frequency {
            switch self {
            case .hertz: .hertz(value)
            case .kilohertz: .kilohertz(value)
            case .megahertz: .megahertz(value)
            case .gigahertz: .gigahertz(value)
            }
        }
    }

    /// The network parameter the file carries. AntScope2 only ever emits `S`.
    public enum Parameter: String, Sendable {
        case scattering = "S"
        case impedance = "Z"
    }

    /// How each pair of numbers on a data line is encoded.
    public enum Format: String, Sendable {
        /// Magnitude and angle in degrees.
        case magnitudeAngle = "MA"
        /// Real and imaginary parts.
        case realImaginary = "RI"
        /// Magnitude in dB and angle in degrees.
        case decibelAngle = "DB"
    }
}

public enum TouchstoneError: Error, Equatable, Sendable {
    case malformedOptionLine(String)
    case unsupportedCombination(parameter: String, format: String)
    case invalidReferenceImpedance(Double)
    case malformedDataLine(line: Int, contents: String)
    case noDataPoints
}

extension TouchstoneFile {
    public static func read(contentsOf url: URL) throws -> TouchstoneFile {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// Parses Touchstone 1.x text.
    ///
    /// Deliberately more permissive than AntScope2's parser, which matches unit keywords
    /// case-sensitively and so rejects the spec's own lowercase `kHz`, and which drops any
    /// data line that happens to contain a `!` anywhere rather than treating it as the
    /// start of a trailing comment.
    public static func parse(_ text: String) throws -> TouchstoneFile {
        var unit: FrequencyUnit = .gigahertz  // Touchstone's default when no option line appears
        var parameter: Parameter = .scattering
        var format: Format = .magnitudeAngle
        var z0: Double = .standardZ0
        var points: [MeasurementPoint] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let withoutComment = rawLine.prefix { $0 != "!" }
            let line = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                (unit, parameter, format, z0) = try parseOptionLine(line)
                continue
            }

            let fields = line.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            guard fields.count >= 3 else {
                throw TouchstoneError.malformedDataLine(line: index + 1, contents: line)
            }

            let impedance = normalizedImpedance(
                first: fields[1], second: fields[2], parameter: parameter, format: format
            )
            points.append(
                MeasurementPoint(
                    frequency: unit.frequency(fields[0]),
                    impedance: Impedance(
                        resistance: impedance.resistance * z0,
                        reactance: impedance.reactance * z0
                    )
                )
            )
        }

        guard !points.isEmpty else { throw TouchstoneError.noDataPoints }
        return TouchstoneFile(points: points, referenceImpedance: z0)
    }

    private static func parseOptionLine(
        _ line: String
    ) throws -> (FrequencyUnit, Parameter, Format, Double) {
        var unit: FrequencyUnit = .gigahertz
        var parameter: Parameter = .scattering
        var format: Format = .magnitudeAngle
        var z0: Double = .standardZ0

        let tokens = line.dropFirst().split(whereSeparator: \.isWhitespace).map { $0.uppercased() }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let matched = FrequencyUnit(rawValue: token) {
                unit = matched
            } else if let matched = Parameter(rawValue: token) {
                parameter = matched
            } else if let matched = Format(rawValue: token) {
                format = matched
            } else if token == "R" {
                guard index + 1 < tokens.count, let value = Double(tokens[index + 1]) else {
                    throw TouchstoneError.malformedOptionLine(line)
                }
                guard value > 0, value <= 10_000 else {
                    throw TouchstoneError.invalidReferenceImpedance(value)
                }
                z0 = value
                index += 1
            } else {
                throw TouchstoneError.malformedOptionLine(line)
            }
            index += 1
        }

        if parameter == .impedance, format != .realImaginary {
            throw TouchstoneError.unsupportedCombination(
                parameter: parameter.rawValue, format: format.rawValue
            )
        }
        return (unit, parameter, format, z0)
    }

    /// Converts one data pair to a normalized impedance.
    ///
    /// Negative resistance is floored at zero and NaN reactance at zero, matching
    /// AntScope2 — noise near the ends of a sweep otherwise produces points that the
    /// downstream passive-load math cannot represent.
    private static func normalizedImpedance(
        first: Double, second: Double, parameter: Parameter, format: Format
    ) -> Impedance {
        var resistance: Double
        var reactance: Double

        switch parameter {
        case .impedance:
            resistance = first
            reactance = second
        case .scattering:
            let gamma: Reflection = switch format {
            case .realImaginary:
                Reflection(real: first, imaginary: second)
            case .magnitudeAngle:
                Reflection(
                    real: first * cos(second / 180 * .pi),
                    imaginary: first * sin(second / 180 * .pi)
                )
            case .decibelAngle:
                {
                    let magnitude = pow(10, first / 20)
                    return Reflection(
                        real: magnitude * cos(second / 180 * .pi),
                        imaginary: magnitude * sin(second / 180 * .pi)
                    )
                }()
            }
            let z = gamma.impedance(referenceImpedance: 1)
            resistance = z.resistance
            reactance = z.reactance
        }

        if resistance.isNaN || resistance < 0 { resistance = 0 }
        if reactance.isNaN { reactance = 0 }
        return Impedance(resistance: resistance, reactance: reactance)
    }
}

extension TouchstoneFile {
    /// Serializes as `# MHz S RI R <z0>`, byte-compatible with what AntScope2 writes.
    public func serialized(comment: String = "Touchstone file generated by RigXSwift") -> String {
        var output = "! \(comment)\n"
        output += "# MHz S RI R \(formatted(referenceImpedance))\n"
        output += "! Format: Frequency S-real S-imaginary (normalized to \(formatted(referenceImpedance)) Ohm)\n"
        for point in points {
            let gamma = point.reflection(referenceImpedance: referenceImpedance)
            let real = gamma.real.isNaN ? 0 : gamma.real
            let imaginary = gamma.imaginary.isNaN ? 0 : gamma.imaginary
            output += "\(formatted(point.frequency.megahertz)) \(formatted(real)) \(formatted(imaginary))\n"
        }
        return output
    }

    public func write(to url: URL, comment: String = "Touchstone file generated by RigXSwift") throws {
        try serialized(comment: comment).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Matches Qt's `QString::number(double)`: up to six significant digits, no trailing zeros.
    private func formatted(_ value: Double) -> String {
        var string = String(format: "%.6g", value)
        if string.contains("e") {
            string = string.replacingOccurrences(of: "e+0", with: "e+")
                .replacingOccurrences(of: "e-0", with: "e-")
        }
        return string
    }
}
