import Foundation

/// A frequency where the reactance vanishes: the antenna's actual electrical resonance.
///
/// Distinct from the frequency of lowest SWR, and the two only coincide when the
/// resistance there happens to equal the system impedance. It is the reactance crossing
/// that tells an operator which way to cut: inductive above it, capacitive below.
public struct Resonance: Sendable, Hashable {
    public var frequency: Frequency
    /// The resistance at the crossing — how close to a match the resonance actually is.
    public var resistance: Double
    /// True when the reactance passes from capacitive to inductive with rising frequency,
    /// which is the series resonance of a dipole-like antenna.
    public var isSeries: Bool

    public init(frequency: Frequency, resistance: Double, isSeries: Bool) {
        self.frequency = frequency
        self.resistance = resistance
        self.isSeries = isSeries
    }
}

/// The lowest point of the SWR curve, refined below the measurement grid.
public struct SWRMinimum: Sendable, Hashable {
    public var frequency: Frequency
    public var swr: Double
    /// The measured sample the minimum was refined from.
    public var sampleIndex: Int

    public init(frequency: Frequency, swr: Double, sampleIndex: Int) {
        self.frequency = frequency
        self.swr = swr
        self.sampleIndex = sampleIndex
    }
}

extension Sweep {
    /// The frequency of lowest SWR.
    ///
    /// The true minimum falls between samples, so a parabola through the lowest sample and
    /// its neighbours locates the vertex. Reporting the lowest *sample* instead ties the
    /// answer to the sweep's resolution: over 1–30 MHz in 500 steps that is a 58 kHz grid,
    /// and the honest error bar on an unrefined answer would be half of it.
    public var minimumSWR: SWRMinimum? {
        let magnitudes = points.map { $0.reflection(referenceImpedance: referenceImpedance).magnitude }
        guard let index = magnitudes.indices.min(by: { magnitudes[$0] < magnitudes[$1] }) else {
            return nil
        }

        var frequency = points[index].frequency.hertz
        var magnitude = magnitudes[index]

        if index > 0, index < points.count - 1 {
            let refined = Self.vertex(
                x0: points[index - 1].frequency.hertz, y0: magnitudes[index - 1],
                x1: points[index].frequency.hertz, y1: magnitudes[index],
                x2: points[index + 1].frequency.hertz, y2: magnitudes[index + 1]
            )
            if let refined,
               refined.x >= points[index - 1].frequency.hertz,
               refined.x <= points[index + 1].frequency.hertz {
                frequency = refined.x
                magnitude = max(0, refined.y)
            }
        }

        guard magnitude < 1 else { return nil }
        return SWRMinimum(
            frequency: Frequency(hertz: frequency),
            swr: (1 + magnitude) / (1 - magnitude),
            sampleIndex: index
        )
    }

    /// Every frequency in the sweep where the reactance crosses zero.
    ///
    /// The crossing is interpolated between the two samples that bracket it, so the answer
    /// is not pinned to the grid either.
    public var resonances: [Resonance] {
        var found: [Resonance] = []
        for index in 1..<max(points.count, 1) {
            let before = points[index - 1]
            let after = points[index]
            let x0 = before.impedance.reactance
            let x1 = after.impedance.reactance
            guard x0 != 0 || x1 != 0, (x0 <= 0 && x1 > 0) || (x0 >= 0 && x1 < 0) else { continue }

            let span = x1 - x0
            let fraction = span == 0 ? 0 : -x0 / span
            let frequency = before.frequency.hertz
                + (after.frequency.hertz - before.frequency.hertz) * fraction
            let resistance = before.impedance.resistance
                + (after.impedance.resistance - before.impedance.resistance) * fraction

            found.append(
                Resonance(
                    frequency: Frequency(hertz: frequency),
                    resistance: resistance,
                    isSeries: x1 > x0
                )
            )
        }
        return found
    }

    /// The resonance nearest the lowest SWR — the one an operator is usually working on.
    public var principalResonance: Resonance? {
        guard let target = minimumSWR?.frequency.hertz else { return resonances.first }
        return resonances.min {
            abs($0.frequency.hertz - target) < abs($1.frequency.hertz - target)
        }
    }

    /// The vertex of the parabola through three points, or nil when they do not describe
    /// one with a minimum.
    private static func vertex(
        x0: Double, y0: Double, x1: Double, y1: Double, x2: Double, y2: Double
    ) -> (x: Double, y: Double)? {
        let d0 = x0 - x1
        let d2 = x2 - x1
        let denominator = d0 * d2 * (d0 - d2)
        guard denominator != 0 else { return nil }

        let a = ((y0 - y1) * d2 - (y2 - y1) * d0) / denominator
        guard a > 0 else { return nil }  // a maximum, or a straight line
        let b = ((y2 - y1) - a * d2 * d2) / d2

        let offset = -b / (2 * a)
        return (x1 + offset, y1 + a * offset * offset + b * offset)
    }
}

/// The feedline inferred from a run of evenly spaced reactance crossings.
///
/// A transmission line repeats its impedance transformation every half wavelength, so an
/// antenna measured through one shows crossings at regular intervals that have nothing to
/// do with the antenna. Read the other way round, that regularity measures the line.
public struct FeedlineEstimate: Sendable, Hashable {
    /// Frequency between successive crossings — a quarter wavelength in the line.
    public var crossingSpacing: Frequency
    /// One-way length the signal covers in free space in the same time. The line's
    /// physical length is this times its velocity factor.
    public var electricalLength: Double
    /// Scatter of the crossings about a straight line, relative to their spacing. Small
    /// means the pattern really is a line's, not an antenna's.
    public var irregularity: Double
    public var crossingCount: Int

    public init(crossingSpacing: Frequency, electricalLength: Double, irregularity: Double, crossingCount: Int) {
        self.crossingSpacing = crossingSpacing
        self.electricalLength = electricalLength
        self.irregularity = irregularity
        self.crossingCount = crossingCount
    }

    public func physicalLength(velocityFactor: Double) -> Double {
        electricalLength * velocityFactor
    }

    public func velocityFactor(physicalLength: Double) -> Double {
        electricalLength > 0 ? physicalLength / electricalLength : 0
    }

    /// Whether the crossings are regular enough to be a line rather than an antenna.
    public var isCredible: Bool { crossingCount >= 3 && irregularity < 0.20 }
}

extension Sweep {
    /// Reads the feedline out of the reactance crossings, when there are enough of them
    /// and they are evenly spaced.
    ///
    /// Three or more crossings in one sweep is almost never an antenna — antennas have one
    /// resonance per mode, decades apart. It is the line between the analyzer and the
    /// antenna, and the interval between crossings measures it.
    ///
    /// The spacing comes from a straight-line fit of crossing frequency against crossing
    /// number rather than from averaging gaps: near the antenna's own resonance one gap
    /// stretches, and a fit absorbs that where a mean would be dragged by it.
    public var feedlineEstimate: FeedlineEstimate? {
        let crossings = resonances
        guard crossings.count >= 3 else { return nil }

        let frequencies = crossings.map(\.frequency.hertz)
        let count = Double(frequencies.count)
        let meanIndex = (count - 1) / 2
        let meanFrequency = frequencies.reduce(0, +) / count

        var covariance = 0.0
        var variance = 0.0
        for (index, frequency) in frequencies.enumerated() {
            let deviation = Double(index) - meanIndex
            covariance += deviation * (frequency - meanFrequency)
            variance += deviation * deviation
        }
        guard variance > 0 else { return nil }
        let spacing = covariance / variance
        guard spacing > 0 else { return nil }

        var squared = 0.0
        for (index, frequency) in frequencies.enumerated() {
            let predicted = meanFrequency + (Double(index) - meanIndex) * spacing
            squared += (frequency - predicted) * (frequency - predicted)
        }
        let scatter = (squared / count).squareRoot()

        // Crossings recur every quarter wavelength; the impedance itself repeats every
        // half, which is what sets the length.
        let halfWaveRepeat = 2 * spacing
        return FeedlineEstimate(
            crossingSpacing: Frequency(hertz: spacing),
            electricalLength: CableMeasurement.speedOfLight / (2 * halfWaveRepeat),
            irregularity: scatter / spacing,
            crossingCount: crossings.count
        )
    }
}

/// How much of a sweep is actually usable.
///
/// An analyzer occasionally loses a sample and reports something impossible rather than
/// nothing. A single one is unremarkable; a scattering of them means the measurement was
/// taken at the edge of what the instrument can do, and is worth repeating.
public struct SweepQuality: Sendable, Hashable {
    public var sampleCount: Int
    /// Samples claiming |Γ| ≥ 1 — more energy returned than was sent. A passive antenna
    /// cannot do that, so these are lost samples, not measurements. Equivalently, they are
    /// the samples that come back with a negative resistance.
    public var saturated: [Frequency]
    /// Samples that are not finite numbers at all.
    public var malformed: [Frequency]

    public init(sampleCount: Int, saturated: [Frequency], malformed: [Frequency]) {
        self.sampleCount = sampleCount
        self.saturated = saturated
        self.malformed = malformed
    }

    public var faultCount: Int { saturated.count + malformed.count }
    public var isClean: Bool { faultCount == 0 }
    public var faultFraction: Double {
        sampleCount > 0 ? Double(faultCount) / Double(sampleCount) : 0
    }

    /// More than a per cent of the sweep in doubt is worth a second run.
    public var deservesRepeating: Bool { faultFraction > 0.01 }
}

extension Sweep {
    public var quality: SweepQuality {
        var saturated: [Frequency] = []
        var malformed: [Frequency] = []
        for point in points {
            let impedance = point.impedance
            guard impedance.resistance.isFinite, impedance.reactance.isFinite else {
                malformed.append(point.frequency)
                continue
            }
            let magnitude = point.reflection(referenceImpedance: referenceImpedance).magnitude
            guard magnitude.isFinite else {
                malformed.append(point.frequency)
                continue
            }
            if magnitude >= 1 { saturated.append(point.frequency) }
        }
        return SweepQuality(sampleCount: points.count, saturated: saturated, malformed: malformed)
    }
}
