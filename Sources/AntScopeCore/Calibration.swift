import Foundation

/// A one-port OSL calibration: what the analyzer read when shown three known loads.
///
/// The correction is the standard three-term error model. Measuring an open, a short and a
/// matched load pins down the three unknowns of the bilinear transform between what the
/// bridge reports and what is actually present, and every later measurement is passed
/// through the inverse.
///
/// This is what removes the residual offset an uncalibrated analyzer shows — a 50 Ω
/// reference reading 47.8 Ω, for instance.
public struct Calibration: Sendable, Hashable, Codable {
    /// What the analyzer reported for each standard, on a shared frequency grid.
    public struct Point: Sendable, Hashable, Codable {
        public var frequency: Frequency
        public var open: Reflection
        public var short: Reflection
        public var load: Reflection

        public init(frequency: Frequency, open: Reflection, short: Reflection, load: Reflection) {
            self.frequency = frequency
            self.open = open
            self.short = short
            self.load = load
        }
    }

    /// The values the standards are assumed to have.
    ///
    /// Ideal ones — a perfect open reflects everything in phase, a perfect short everything
    /// inverted, a perfect load nothing. Real standards depart from this (an open has
    /// fringing capacitance, a short some inductance), and a characterised kit would supply
    /// its own model here; at HF the ideal assumption costs very little.
    public struct Standards: Sendable, Hashable, Codable {
        public var open: Reflection
        public var short: Reflection
        public var load: Reflection

        public static let ideal = Standards(
            open: Reflection(real: 1, imaginary: 0),
            short: Reflection(real: -1, imaginary: 0),
            load: Reflection(real: 0, imaginary: 0)
        )

        public init(open: Reflection, short: Reflection, load: Reflection) {
            self.open = open
            self.short = short
            self.load = load
        }
    }

    /// Sorted by frequency.
    public var points: [Point]
    public var standards: Standards
    public var referenceImpedance: Double
    public var date: Date
    /// Which analyzer this was made with, so a calibration cannot be applied to another.
    public var analyzerSerial: String?

    public init(
        points: [Point],
        standards: Standards = .ideal,
        referenceImpedance: Double = .standardZ0,
        date: Date = Date(),
        analyzerSerial: String? = nil
    ) {
        self.points = points.sorted { $0.frequency < $1.frequency }
        self.standards = standards
        self.referenceImpedance = referenceImpedance
        self.date = date
        self.analyzerSerial = analyzerSerial
    }

    public var frequencyRange: ClosedRange<Frequency>? {
        guard let first = points.first, let last = points.last else { return nil }
        return first.frequency...last.frequency
    }

    public var isUsable: Bool { points.count >= 2 }
}

extension Calibration {
    /// Builds a calibration from three sweeps of the same grid.
    ///
    /// The three must share their frequencies: the correction at a point needs all three
    /// standards *at that point*, and pairing samples measured at different frequencies
    /// would silently produce a plausible, wrong answer.
    public init?(open: Sweep, short: Sweep, load: Sweep, analyzerSerial: String? = nil) {
        guard open.points.count == short.points.count,
              open.points.count == load.points.count,
              open.points.count >= 2
        else { return nil }

        let z0 = open.referenceImpedance
        var points: [Point] = []
        points.reserveCapacity(open.points.count)

        for index in open.points.indices {
            let frequency = open.points[index].frequency
            let tolerance = max(frequency.hertz * 1e-6, 1)
            guard abs(short.points[index].frequency.hertz - frequency.hertz) < tolerance,
                  abs(load.points[index].frequency.hertz - frequency.hertz) < tolerance
            else { return nil }

            points.append(
                Point(
                    frequency: frequency,
                    open: open.points[index].reflection(referenceImpedance: z0),
                    short: short.points[index].reflection(referenceImpedance: z0),
                    load: load.points[index].reflection(referenceImpedance: z0)
                )
            )
        }
        self.init(points: points, referenceImpedance: z0, analyzerSerial: analyzerSerial)
    }

    /// The three measured standards at an arbitrary frequency.
    ///
    /// Linear interpolation between the bracketing grid points; outside the calibrated
    /// range the nearest end is held rather than extrapolated, since extrapolating an error
    /// model past its evidence produces confident nonsense.
    public func standardsMeasured(at frequency: Frequency) -> (open: Complex, short: Complex, load: Complex)? {
        guard points.count >= 2 else { return nil }

        if frequency <= points[0].frequency {
            return (points[0].open.complex, points[0].short.complex, points[0].load.complex)
        }
        if let last = points.last, frequency >= last.frequency {
            return (last.open.complex, last.short.complex, last.load.complex)
        }

        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].frequency <= frequency { low = middle } else { high = middle }
        }

        let span = points[high].frequency.hertz - points[low].frequency.hertz
        let fraction = span > 0 ? (frequency.hertz - points[low].frequency.hertz) / span : 0
        return (
            points[low].open.complex.interpolated(to: points[high].open.complex, at: fraction),
            points[low].short.complex.interpolated(to: points[high].short.complex, at: fraction),
            points[low].load.complex.interpolated(to: points[high].load.complex, at: fraction)
        )
    }

    /// Corrects one measurement.
    public func corrected(_ measured: Reflection, at frequency: Frequency) -> Reflection {
        guard let m = standardsMeasured(at: frequency) else { return measured }

        let sOpen = standards.open.complex
        let sShort = standards.short.complex
        let sLoad = standards.load.complex

        // Three-term error model: solve for the bilinear transform that maps what the
        // bridge reported for the standards onto what they actually are.
        let k1 = m.load - m.short
        let k2 = m.short - m.open
        let k3 = m.open - m.load

        let k4 = k1 * sLoad * sShort
        let k5 = k2 * sOpen * sShort
        let k6 = k3 * sLoad * sOpen
        let k7 = sOpen * k1
        let k8 = sLoad * k2
        let k9 = sShort * k3

        let d = k4 + k5 + k6
        guard d.squaredMagnitude > 0 else { return measured }

        let a = (m.open * k7 + m.load * k8 + m.short * k9) / d
        let b = (m.open * k4 + m.load * k5 + m.short * k6) / d
        let c = (k7 + k8 + k9) / d

        let value = measured.complex
        let denominator = a - c * value
        guard denominator.squaredMagnitude > 0 else { return measured }

        let corrected = (value - b) / denominator
        guard corrected.real.isFinite, corrected.imaginary.isFinite else { return measured }
        // Deliberately not clamped inside the unit circle. AntScope2 pulls an over-unity
        // result back to 0.999999992, which turns a sample the analyzer failed to measure
        // into a valid-looking one whose SWR is 250 million. Left alone it stays what it
        // is — impossible — and `Sweep.quality` counts it.
        return Reflection(corrected)
    }

    /// Corrects a whole sweep.
    public func corrected(_ sweep: Sweep) -> Sweep {
        var result = sweep
        result.points = sweep.points.map { point in
            let measured = point.reflection(referenceImpedance: sweep.referenceImpedance)
            let fixed = corrected(measured, at: point.frequency)
            return MeasurementPoint(
                frequency: point.frequency,
                impedance: fixed.impedance(referenceImpedance: sweep.referenceImpedance)
            )
        }
        return result
    }
}
