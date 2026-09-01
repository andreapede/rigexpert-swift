import Testing
@testable import AntScopeCore

@Suite("Complex arithmetic")
struct ComplexTests {
    @Test("Multiplication and division are inverses")
    func roundTrip() {
        let a = Complex(0.37, -0.82)
        let b = Complex(-1.4, 0.55)
        let back = (a * b) / b
        #expect(abs(back.real - a.real) < 1e-12)
        #expect(abs(back.imaginary - a.imaginary) < 1e-12)
    }

    @Test("i squared is minus one")
    func imaginaryUnit() {
        let i = Complex(0, 1)
        #expect((i * i).real.isApproximately(-1))
        #expect((i * i).imaginary.isApproximately(0))
    }

    @Test("Dividing by zero yields not-a-number rather than a wrong answer")
    func divideByZero() {
        #expect((Complex(1, 1) / .zero).real.isNaN)
    }
}

@Suite("OSL calibration")
struct CalibrationTests {
    /// An analyzer with a known systematic error.
    ///
    /// The three-term model says every real bridge maps the truth through some bilinear
    /// transform `Γ_measured = (A·Γ + B) / (1 + C·Γ)`. Inventing one, measuring the
    /// standards through it and checking the calibration inverts it exactly is the
    /// strongest test available without a laboratory.
    struct ErrorNetwork {
        let a: Complex
        let b: Complex
        let c: Complex

        func measure(_ actual: Reflection) -> Reflection {
            let value = actual.complex
            return Reflection((a * value + b) / (Complex.one + c * value))
        }
    }

    static let network = ErrorNetwork(
        a: Complex(0.95, 0.02),
        b: Complex(0.03, -0.01),
        c: Complex(0.04, 0.01)
    )

    static func calibration(over frequencies: [Frequency] = [.megahertz(1), .megahertz(30)]) -> Calibration {
        let ideal = Calibration.Standards.ideal
        let points = frequencies.map { frequency in
            Calibration.Point(
                frequency: frequency,
                open: network.measure(ideal.open),
                short: network.measure(ideal.short),
                load: network.measure(ideal.load)
            )
        }
        return Calibration(points: points)
    }

    @Test("A known error network is inverted exactly", arguments: [
        Impedance(resistance: 75, reactance: 0),
        Impedance(resistance: 25, reactance: 0),
        Impedance(resistance: 50, reactance: 0),
        Impedance(resistance: 120, reactance: -60),
        Impedance(resistance: 8, reactance: 30),
    ])
    func invertsTheError(load: Impedance) {
        let truth = Reflection(impedance: load)
        let measured = Self.network.measure(truth)
        let corrected = Self.calibration().corrected(measured, at: .megahertz(14))

        #expect(abs(corrected.real - truth.real) < 1e-9)
        #expect(abs(corrected.imaginary - truth.imaginary) < 1e-9)
    }

    @Test("The offset an uncalibrated analyzer shows is removed")
    func removesResidualOffset() {
        // Our AA-30.ZERO reads a 50 ohm reference as 47.8 ohm. After calibration a
        // matched load has to come back matched.
        let truth = Reflection(impedance: Impedance(resistance: 50, reactance: 0))
        let measured = Self.network.measure(truth)
        #expect(measured.impedance().resistance != 50, "the synthetic bridge is biased")

        let corrected = Self.calibration().corrected(measured, at: .megahertz(14))
        #expect(abs(corrected.impedance().resistance - 50) < 1e-6)
        #expect(abs(corrected.impedance().reactance) < 1e-6)
        #expect(abs(corrected.swr! - 1) < 1e-6)
    }

    @Test("Correction is interpolated between calibrated frequencies")
    func interpolates() {
        let calibration = Self.calibration(over: [.megahertz(1), .megahertz(10), .megahertz(30)])
        let standards = calibration.standardsMeasured(at: .megahertz(5))
        let atGrid = calibration.standardsMeasured(at: .megahertz(10))
        // The network here is frequency independent, so every point must agree.
        #expect(abs(standards!.load.real - atGrid!.load.real) < 1e-12)
    }

    @Test("Outside the calibrated range the nearest end is held, not extrapolated")
    func clampsOutsideRange() {
        let calibration = Self.calibration(over: [.megahertz(10), .megahertz(20)])
        let below = calibration.standardsMeasured(at: .megahertz(1))
        let atStart = calibration.standardsMeasured(at: .megahertz(10))
        #expect(below!.open == atStart!.open)

        let above = calibration.standardsMeasured(at: .megahertz(500))
        let atEnd = calibration.standardsMeasured(at: .megahertz(20))
        #expect(above!.short == atEnd!.short)
    }

    @Test("An impossible sample stays impossible after correction")
    func doesNotRescueASaturatedSample() {
        // A sample the analyzer failed on: |Γ| beyond the unit circle. Pulling it back
        // just inside would give it an SWR of a quarter of a billion and hide the fault
        // from `Sweep.quality`, which is what counts such things.
        let impossible = Reflection(real: 1.04, imaginary: 0.02)
        #expect(impossible.magnitude > 1)

        let corrected = Self.calibration().corrected(impossible, at: .megahertz(14))
        #expect(corrected.swr == nil, "no finite SWR should be invented for it")
    }

    @Test("Sweeps measured on different grids are refused")
    func rejectsMismatchedGrids() {
        func sweep(_ megahertz: [Double]) -> Sweep {
            Sweep(name: "x", points: megahertz.map {
                MeasurementPoint(
                    frequency: .megahertz($0),
                    impedance: Impedance(resistance: 60, reactance: 5)
                )
            })
        }
        #expect(Calibration(open: sweep([1, 2]), short: sweep([1, 2]), load: sweep([1, 3])) == nil)
        #expect(Calibration(open: sweep([1, 2]), short: sweep([1, 2, 3]), load: sweep([1, 2])) == nil)
        #expect(Calibration(open: sweep([1, 2]), short: sweep([1, 2]), load: sweep([1, 2])) != nil)
    }

    @Test("A whole sweep is corrected point by point")
    func correctsASweep() {
        let truths = [
            Impedance(resistance: 50, reactance: 0),
            Impedance(resistance: 75, reactance: 20),
            Impedance(resistance: 30, reactance: -15),
        ]
        let measured = Sweep(name: "raw", points: truths.enumerated().map { index, impedance in
            MeasurementPoint(
                frequency: .megahertz(Double(index + 1)),
                impedance: Self.network.measure(Reflection(impedance: impedance)).impedance()
            )
        })

        let corrected = Self.calibration().corrected(measured)
        for (point, truth) in zip(corrected.points, truths) {
            #expect(abs(point.impedance.resistance - truth.resistance) < 1e-6)
            #expect(abs(point.impedance.reactance - truth.reactance) < 1e-6)
        }
    }
}
