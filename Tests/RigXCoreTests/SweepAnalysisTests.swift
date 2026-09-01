import Foundation
import Testing
@testable import RigXCore

@Suite("Sweep analysis")
struct SweepAnalysisTests {
    /// A series RLC seen through 50 ohm: the textbook model of a resonant antenna.
    ///
    /// Resonance sits exactly at 1/(2π√(LC)) and the resistance there is R, so both
    /// answers are known in advance and the sweep grid deliberately misses them.
    static func resonant(
        resistance: Double,
        resonanceMHz: Double,
        quality: Double,
        from startMHz: Double,
        to endMHz: Double,
        points: Int
    ) -> Sweep {
        let f0 = resonanceMHz * 1e6
        let inductance = quality * resistance / (2 * .pi * f0)
        let capacitance = 1 / (inductance * pow(2 * .pi * f0, 2))

        let samples = (0...points).map { index -> MeasurementPoint in
            let megahertz = startMHz + (endMHz - startMHz) * Double(index) / Double(points)
            let omega = 2 * .pi * megahertz * 1e6
            let reactance = omega * inductance - 1 / (omega * capacitance)
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(resistance: resistance, reactance: reactance)
            )
        }
        return Sweep(name: "resonant", points: samples)
    }

    @Test("Resonance is found between samples, not on the grid")
    func findsResonanceOffGrid() throws {
        // 14.137 MHz cannot land on this grid: 200 steps over 1 MHz is a 5 kHz spacing.
        let sweep = Self.resonant(
            resistance: 50, resonanceMHz: 14.137, quality: 12,
            from: 13.5, to: 14.5, points: 200
        )
        let resonance = try #require(sweep.principalResonance)
        #expect(abs(resonance.frequency.megahertz - 14.137) < 0.001)
        #expect(abs(resonance.resistance - 50) < 0.01)
        #expect(resonance.isSeries)
    }

    @Test("Resonance and lowest SWR differ when the antenna is not 50 ohm")
    func resonanceIsNotTheSWRMinimum() throws {
        // A 30 ohm antenna: minimum SWR still lands at the reactance crossing here,
        // because R is constant — but the SWR there is 50/30, not 1.
        let sweep = Self.resonant(
            resistance: 30, resonanceMHz: 21.2, quality: 10,
            from: 20.5, to: 22, points: 300
        )
        let minimum = try #require(sweep.minimumSWR)
        let resonance = try #require(sweep.principalResonance)

        #expect(abs(resonance.resistance - 30) < 0.05)
        #expect(abs(minimum.swr - 50.0 / 30.0) < 0.01, "a 30 ohm resonance cannot do better than 1.67")
    }

    @Test("The refined minimum beats the best sample")
    func refinesTheMinimum() throws {
        let sweep = Self.resonant(
            resistance: 50, resonanceMHz: 14.137, quality: 12,
            from: 13.5, to: 14.5, points: 40  // 25 kHz grid
        )
        let minimum = try #require(sweep.minimumSWR)
        let nearestSample = sweep.points[minimum.sampleIndex].frequency.megahertz

        let refinedError = abs(minimum.frequency.megahertz - 14.137)
        let sampleError = abs(nearestSample - 14.137)
        #expect(refinedError < sampleError, "interpolation has to improve on the grid")
        #expect(refinedError < 0.005)
    }

    @Test("A sweep with no crossing reports no resonance")
    func noResonance() {
        let samples = (0...100).map { index in
            MeasurementPoint(
                frequency: .megahertz(1 + Double(index) * 0.29),
                impedance: Impedance(resistance: 40, reactance: -25)  // always capacitive
            )
        }
        let sweep = Sweep(name: "no crossing", points: samples)
        #expect(sweep.resonances.isEmpty)
        #expect(sweep.principalResonance == nil)
        #expect(sweep.minimumSWR != nil, "there is still a lowest SWR")
    }

    @Test("Several crossings are all reported")
    func multipleResonances() {
        let samples = (0...400).map { index -> MeasurementPoint in
            let megahertz = 1 + Double(index) * 0.0725
            // 2.9 periods across the span, offset so no sample sits exactly on a zero:
            // the phase runs from 0.3 to 18.52 rad, crossing a multiple of pi five times.
            let reactance = 40 * sin(2 * .pi * (megahertz - 1) / 10 + 0.3)
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(resistance: 45, reactance: reactance)
            )
        }
        #expect(Sweep(name: "multi", points: samples).resonances.count == 5)
    }

    @Test("Analysis follows the sweep's own reference impedance")
    func honoursReferenceImpedance() throws {
        let samples = (0...50).map { index in
            MeasurementPoint(
                frequency: .megahertz(10 + Double(index) * 0.1),
                impedance: Impedance(resistance: 75, reactance: 0)
            )
        }
        let at50 = Sweep(name: "a", referenceImpedance: 50, points: samples)
        let at75 = Sweep(name: "b", referenceImpedance: 75, points: samples)

        #expect(abs(try #require(at50.minimumSWR).swr - 1.5) < 1e-6)
        #expect(abs(try #require(at75.minimumSWR).swr - 1.0) < 1e-6, "matched in a 75 ohm system")
    }
}

@Suite("Sweep quality")
struct SweepQualityTests {
    static func sweep(_ impedances: [Impedance]) -> Sweep {
        Sweep(name: "q", points: impedances.enumerated().map { index, impedance in
            MeasurementPoint(frequency: .megahertz(Double(index + 1)), impedance: impedance)
        })
    }

    @Test("A clean sweep reports no faults")
    func clean() {
        let sweep = Self.sweep((0..<50).map { Impedance(resistance: 50 + Double($0), reactance: -5) })
        #expect(sweep.quality.isClean)
        #expect(sweep.quality.faultCount == 0)
        #expect(!sweep.quality.deservesRepeating)
    }

    @Test("A negative resistance is counted as a lost sample")
    func negativeResistance() {
        // The real case: an AA-30.ZERO reported R = -0.47, X = 21.55 at 113 MHz.
        var impedances = (0..<100).map { _ in Impedance(resistance: 50, reactance: 0) }
        impedances[42] = Impedance(resistance: -0.47, reactance: 21.55)
        let quality = Self.sweep(impedances).quality

        #expect(quality.faultCount == 1)
        #expect(quality.saturated.first == .megahertz(43))
        #expect(!quality.deservesRepeating, "one in a hundred is not a bad sweep")
    }

    @Test("Infinities are separated from merely impossible values")
    func malformed() {
        var impedances = (0..<20).map { _ in Impedance(resistance: 50, reactance: 0) }
        impedances[3] = Impedance(resistance: .infinity, reactance: 0)
        impedances[7] = Impedance(resistance: .nan, reactance: 1)
        let quality = Self.sweep(impedances).quality

        #expect(quality.malformed.count == 2)
        #expect(quality.saturated.isEmpty)
    }

    @Test("A sweep riddled with faults asks to be repeated")
    func deservesRepeating() {
        let impedances = (0..<100).map { index in
            index % 20 == 0
                ? Impedance(resistance: -1, reactance: 5)
                : Impedance(resistance: 50, reactance: 0)
        }
        #expect(Self.sweep(impedances).quality.deservesRepeating)
    }
}
