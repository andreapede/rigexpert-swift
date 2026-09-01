import Foundation
import Testing
@testable import RigXCore

@Suite("Time domain reflectometry")
struct TimeDomainTests {
    /// A load seen through a lossless line of known length.
    static func line(
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
            let tangent = tan(2 * Double.pi / wavelength * lengthMetres)
            let zin = ((load + Complex(0, z0 * tangent)) * z0)
                / (Complex(z0, 0) + load * Complex(0, tangent))
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(resistance: zin.real, reactance: zin.imaginary)
            )
        }
        return Sweep(name: "line", points: samples)
    }

    @Test("An open at the end of a known line shows up at its distance", arguments: [
        3.0, 6.0, 12.0,
    ])
    func findsTheEnd(length: Double) throws {
        // An open reflects everything, so the far end is the only feature of any size.
        let sweep = Self.line(load: Complex(1e6, 0), lengthMetres: length, velocityFactor: 0.66)
        let response = try #require(TimeDomain.transform(sweep, velocityFactor: 0.66))
        let peak = try #require(response.dominantDiscontinuity)

        #expect(abs(peak.distance - length) < response.resolution,
                "found at \(peak.distance) m, expected \(length) m ± \(response.resolution)")
    }

    @Test("Resolution follows the bandwidth, and the window makes it worse")
    func resolutionIsHonest() throws {
        let sweep = Self.line(load: Complex(1e6, 0), lengthMetres: 5, velocityFactor: 0.66)

        let bare = try #require(TimeDomain.transform(sweep, velocityFactor: 0.66, window: .none))
        let expected = CableMeasurement.speedOfLight * 0.66 / (2 * 169e6)
        #expect(abs(bare.resolution - expected) < 0.01)

        let hann = try #require(TimeDomain.transform(sweep, velocityFactor: 0.66, window: .hann))
        #expect(hann.resolution > bare.resolution)
        #expect(abs(hann.resolution / bare.resolution - TDRWindow.hann.resolutionPenalty) < 0.01)
    }

    @Test("A narrow sweep cannot resolve a short cable, and says so")
    func narrowBandCannotResolve() throws {
        // 1-30 MHz is the calibrated range on an AA-30.ZERO. Three metres of resolution
        // is not enough to see a three metre patch lead, and the number has to admit it.
        let sweep = Self.line(
            load: Complex(1e6, 0), lengthMetres: 3, velocityFactor: 0.66, from: 1, to: 30
        )
        let response = try #require(TimeDomain.transform(sweep, velocityFactor: 0.66))
        #expect(response.resolution > 3, "resolution here is worse than the cable is long")
    }

    @Test("The velocity factor scales the distance axis")
    func velocityFactorScalesDistance() throws {
        let sweep = Self.line(load: Complex(1e6, 0), lengthMetres: 5, velocityFactor: 0.66)
        let correct = try #require(TimeDomain.transform(sweep, velocityFactor: 0.66))
        let wrong = try #require(TimeDomain.transform(sweep, velocityFactor: 0.80))

        let a = try #require(correct.dominantDiscontinuity).distance
        let b = try #require(wrong.dominantDiscontinuity).distance
        #expect(abs(b / a - 0.80 / 0.66) < 0.05, "distance scales with the factor given")
    }

    @Test("A matched line has nothing to show")
    func matchedLineIsFlat() throws {
        let sweep = Self.line(load: Complex(50, 0), lengthMetres: 5, velocityFactor: 0.66)
        let response = try #require(TimeDomain.transform(sweep, velocityFactor: 0.66))
        let peak = response.dominantDiscontinuity?.magnitude ?? 0
        #expect(peak < 0.02, "a matched load reflects nothing to find")
    }

    @Test("A sweep that is not on a uniform grid is refused")
    func refusesNonUniformSweeps() {
        let samples = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0].map {
            MeasurementPoint(frequency: .megahertz($0), impedance: Impedance(resistance: 40, reactance: 10))
        }
        #expect(TimeDomain.transform(Sweep(name: "log", points: samples), velocityFactor: 0.66) == nil)
    }

    @Test("Too few points is refused outright")
    func refusesTinySweeps() {
        let samples = (0..<5).map {
            MeasurementPoint(frequency: .megahertz(Double($0 + 1)), impedance: Impedance(resistance: 40, reactance: 10))
        }
        #expect(TimeDomain.transform(Sweep(name: "tiny", points: samples), velocityFactor: 0.66) == nil)
    }
}
