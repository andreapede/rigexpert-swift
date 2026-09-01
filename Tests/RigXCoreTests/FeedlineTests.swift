import Foundation
import Testing
@testable import RigXCore

@Suite("Feedline from crossing spacing")
struct FeedlineTests {
    /// A load seen through a length of line: the textbook transformation.
    ///
    /// `Zin = Z0 (ZL + j Z0 tan βl) / (Z0 + j ZL tan βl)`
    static func throughLine(
        load: Complex,
        lengthMetres: Double,
        velocityFactor: Double,
        z0: Double = 50,
        from startMHz: Double = 1,
        to endMHz: Double = 170,
        points: Int = 500
    ) -> Sweep {
        let samples = (0...points).map { index -> MeasurementPoint in
            let megahertz = startMHz + (endMHz - startMHz) * Double(index) / Double(points)
            let wavelength = CableMeasurement.speedOfLight * velocityFactor / (megahertz * 1e6)
            let beta = 2 * Double.pi / wavelength
            let tangent = tan(beta * lengthMetres)

            let numerator = (load + Complex(0, z0 * tangent)) * z0
            let denominator = Complex(z0, 0) + load * Complex(0, tangent)
            let zin = numerator / denominator
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(resistance: zin.real, reactance: zin.imaginary)
            )
        }
        return Sweep(name: "through line", points: samples)
    }

    @Test("The line's length falls out of the crossing spacing", arguments: [
        (1.66, 0.66), (3.0, 0.66), (1.0, 0.80),
    ])
    func recoversLineLength(length: Double, velocityFactor: Double) throws {
        // A stubbornly mismatched load, so the crossings come from the line alone.
        let sweep = Self.throughLine(
            load: Complex(12, -40), lengthMetres: length, velocityFactor: velocityFactor
        )
        let estimate = try #require(sweep.feedlineEstimate)

        #expect(estimate.isCredible)
        #expect(abs(estimate.physicalLength(velocityFactor: velocityFactor) - length) < 0.05)
        #expect(abs(estimate.velocityFactor(physicalLength: length) - velocityFactor) < 0.02)
    }

    @Test("A lone antenna resonance is not mistaken for a feedline")
    func ignoresASingleResonance() {
        // One reactance crossing: the antenna itself, measured at its terminals.
        let samples = (0...400).map { index -> MeasurementPoint in
            let megahertz = 60 + Double(index) * 0.05
            let detune = (megahertz - 67.6) / 67.6
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(resistance: 52, reactance: 900 * detune)
            )
        }
        let sweep = Sweep(name: "bare dipole", points: samples)
        #expect(sweep.resonances.count == 1)
        #expect(sweep.feedlineEstimate == nil, "one crossing cannot describe a line")
    }

    @Test("Crossings that are not evenly spaced are refused")
    func rejectsIrregularCrossings() throws {
        // Reactance wandering through zero at arbitrary intervals.
        let breaks: [Double] = [10, 12, 40, 95, 100]
        let samples = (0...600).map { index -> MeasurementPoint in
            let megahertz = 1 + Double(index) * 0.28
            let sign = breaks.reduce(1.0) { $0 * (megahertz < $1 ? -1 : 1) }
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(resistance: 40, reactance: sign * 60)
            )
        }
        let sweep = Sweep(name: "irregular", points: samples)
        #expect(sweep.resonances.count == breaks.count)
        #expect(sweep.feedlineEstimate?.isCredible != true)
    }
}
