import Foundation
import Testing
@testable import RigXCore

@Suite("Cable measurement")
struct CableAnalysisTests {
    /// Builds the sweep a cable of the given length would produce.
    static func synthesize(
        lengthMetres: Double,
        velocityFactor: Double,
        near: Complex,
        far: Complex,
        from startMHz: Double = 1,
        to endMHz: Double = 30,
        points: Int = 500,
        noise: Double = 0
    ) -> (Sweep, Double) {
        let delay = 2 * lengthMetres / (CableMeasurement.speedOfLight * velocityFactor)
        var generator = SystemRandomNumberGenerator()
        let samples = (0...points).map { index -> MeasurementPoint in
            let megahertz = startMHz + (endMHz - startMHz) * Double(index) / Double(points)
            let frequency = Frequency.megahertz(megahertz)
            var gamma = near + far * Complex.unit(angle: -2 * .pi * frequency.hertz * delay)
            if noise > 0 {
                gamma = gamma + Complex(
                    Double.random(in: -noise...noise, using: &generator),
                    Double.random(in: -noise...noise, using: &generator)
                )
            }
            return MeasurementPoint(
                frequency: frequency,
                impedance: Reflection(gamma).impedance()
            )
        }
        return (Sweep(name: "synthetic", points: samples), delay)
    }

    @Test("A known cable is recovered", arguments: [
        (2.97, 0.66), (10.0, 0.66), (5.0, 0.80), (1.5, 0.695),
    ])
    func recoversLength(length: Double, velocityFactor: Double) throws {
        let (sweep, delay) = Self.synthesize(
            lengthMetres: length,
            velocityFactor: velocityFactor,
            near: Complex(0.036, -0.001),
            far: Complex(-0.029, 0.009)
        )
        let measured = try #require(CableAnalyzer.measure(sweep))

        #expect(abs(measured.roundTripDelay - delay) / delay < 0.01)
        #expect(abs(measured.physicalLength(velocityFactor: velocityFactor) - length) < 0.02)
        #expect(abs(measured.velocityFactor(physicalLength: length) - velocityFactor) < 0.01)
        #expect(measured.isCredible)
    }

    @Test("The two reflections are separated")
    func separatesReflections() throws {
        let near = Complex(0.036, -0.001)
        let far = Complex(-0.029, 0.009)
        let (sweep, _) = Self.synthesize(lengthMetres: 2.97, velocityFactor: 0.66, near: near, far: far)
        let measured = try #require(CableAnalyzer.measure(sweep))

        #expect(abs(measured.nearReflection.magnitude - near.magnitude) < 0.002)
        #expect(abs(measured.farReflection.magnitude - far.magnitude) < 0.002)
    }

    @Test("Measurement noise degrades the fit without breaking it")
    func survivesNoise() throws {
        let (sweep, delay) = Self.synthesize(
            lengthMetres: 2.97, velocityFactor: 0.66,
            near: Complex(0.036, 0), far: Complex(-0.029, 0),
            noise: 0.004
        )
        let measured = try #require(CableAnalyzer.measure(sweep))
        #expect(abs(measured.roundTripDelay - delay) / delay < 0.05)
        #expect(measured.residual > 0, "noise has to show up somewhere")
    }

    @Test("A sweep with nothing to reflect is reported as not credible")
    func rejectsAFlatSweep() throws {
        let samples = (0...200).map { index in
            MeasurementPoint(
                frequency: .megahertz(1 + Double(index) * 0.145),
                impedance: Impedance(resistance: 50, reactance: 0)
            )
        }
        let measured = CableAnalyzer.measure(Sweep(name: "matched", points: samples))
        #expect(measured?.isCredible != true)
    }

    @Test("Too few points is refused outright")
    func refusesTinySweeps() {
        let samples = (0..<4).map {
            MeasurementPoint(
                frequency: .megahertz(Double($0 + 1)),
                impedance: Impedance(resistance: 60, reactance: 3)
            )
        }
        #expect(CableAnalyzer.measure(Sweep(name: "tiny", points: samples)) == nil)
    }
}
