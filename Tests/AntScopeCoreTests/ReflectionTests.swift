import Testing
@testable import AntScopeCore

@Suite("Reflection coefficient")
struct ReflectionTests {
    @Test("A matched 50 ohm load reflects nothing")
    func matchedLoad() {
        let gamma = Reflection(impedance: Impedance(resistance: 50, reactance: 0))
        #expect(gamma.magnitude.isApproximately(0))
        #expect(gamma.swr!.isApproximately(1))
        #expect(gamma.returnLossDecibels == .infinity)
    }

    @Test("Doubling the resistance gives SWR 2 and about 9.54 dB return loss")
    func mismatchedLoad() {
        let gamma = Reflection(impedance: Impedance(resistance: 100, reactance: 0))
        #expect(gamma.real.isApproximately(1.0 / 3.0))
        #expect(gamma.imaginary.isApproximately(0))
        #expect(gamma.swr!.isApproximately(2))
        #expect(gamma.returnLossDecibels.isApproximately(9.542425, tolerance: 1e-5))
    }

    @Test("Halving the resistance also gives SWR 2, with Gamma inverted")
    func mismatchedLoadBelowZ0() {
        let gamma = Reflection(impedance: Impedance(resistance: 25, reactance: 0))
        #expect(gamma.real.isApproximately(-1.0 / 3.0))
        #expect(gamma.swr!.isApproximately(2))
    }

    @Test("A dead short reflects everything with a 180 degree phase flip")
    func shortCircuit() {
        let gamma = Reflection(impedance: Impedance(resistance: 0, reactance: 0))
        #expect(gamma.real.isApproximately(-1))
        #expect(gamma.imaginary.isApproximately(0))
        #expect(gamma.phaseDegrees.isApproximately(180))
        #expect(gamma.swr == nil, "|Gamma| = 1 has no finite SWR")
    }

    @Test("Reactance rotates Gamma without changing its magnitude")
    func reactiveLoad() {
        let resistive = Reflection(impedance: Impedance(resistance: 50, reactance: 0))
        let inductive = Reflection(impedance: Impedance(resistance: 50, reactance: 50))
        #expect(inductive.magnitude > resistive.magnitude)
        #expect(inductive.phaseDegrees > 0, "inductive loads sit above the real axis")

        let capacitive = Reflection(impedance: Impedance(resistance: 50, reactance: -50))
        #expect(capacitive.phaseDegrees < 0)
        #expect(capacitive.magnitude.isApproximately(inductive.magnitude))
    }

    @Test("Impedance survives a round trip through Gamma", arguments: [
        Impedance(resistance: 50, reactance: 0),
        Impedance(resistance: 12.5, reactance: -37),
        Impedance(resistance: 300, reactance: 120),
        Impedance(resistance: 0.5, reactance: 0.25),
    ])
    func roundTrip(impedance: Impedance) {
        let recovered = Reflection(impedance: impedance).impedance()
        #expect(recovered.resistance.isApproximately(impedance.resistance, tolerance: 1e-9))
        #expect(recovered.reactance.isApproximately(impedance.reactance, tolerance: 1e-9))
    }

    @Test("Gamma matches the normalized form AntScope2 uses for phase and Smith plots")
    func agreesWithNormalizedFormulation() {
        // measurements.cpp computes Gamma twice, once from raw R and X and once from
        // R/Z0 and X/Z0. The two must agree or the SWR plot and the Smith trace disagree.
        for (r, x) in [(75.0, 30.0), (10.0, -80.0), (50.0, 0.0), (600.0, 15.0)] {
            let direct = Reflection(impedance: Impedance(resistance: r, reactance: x))

            let rNorm = r / 50, xNorm = x / 50
            let denominator = (rNorm + 1) * (rNorm + 1) + xNorm * xNorm
            let normalized = Reflection(
                real: ((rNorm - 1) * (rNorm + 1) + xNorm * xNorm) / denominator,
                imaginary: 2 * xNorm / denominator
            )

            #expect(direct.real.isApproximately(normalized.real, tolerance: 1e-12))
            #expect(direct.imaginary.isApproximately(normalized.imaginary, tolerance: 1e-12))
        }
    }

    @Test("An over-unity Gamma is pulled back inside the unit circle")
    func clamping() {
        let overshoot = Reflection(real: 1.4, imaginary: 0.3)
        let clamped = overshoot.clampedInsideUnitCircle()
        #expect(clamped.magnitude < 1)
        #expect(clamped.magnitude.isApproximately(0.999_999_992, tolerance: 1e-9))
        #expect(clamped.phaseDegrees.isApproximately(overshoot.phaseDegrees, tolerance: 1e-9))

        let inside = Reflection(real: 0.5, imaginary: 0.1)
        #expect(inside.clampedInsideUnitCircle() == inside, "points inside are untouched")
    }
}

@Suite("Impedance")
struct ImpedanceTests {
    @Test("Series to parallel conversion")
    func parallelEquivalent() {
        let parallel = Impedance(resistance: 50, reactance: 50).parallelEquivalent
        #expect(parallel.resistance.isApproximately(100))
        #expect(parallel.reactance.isApproximately(100))
    }

    @Test("Magnitude is the hypotenuse")
    func magnitude() {
        #expect(Impedance(resistance: 3, reactance: 4).magnitude.isApproximately(5))
    }
}

extension Double {
    func isApproximately(_ other: Double, tolerance: Double = 1e-10) -> Bool {
        abs(self - other) <= tolerance
    }
}
