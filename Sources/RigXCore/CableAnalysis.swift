import Foundation

/// What a sweep reveals about the cable between the analyzer and whatever terminates it.
///
/// A cable with anything but a perfect termination sends back two reflections: one from
/// the near junction, one delayed by the round trip to the far end. They interfere, and
/// the frequency at which the interference repeats is a direct measure of the round-trip
/// time — which is to say, of the cable's electrical length.
///
/// The measurement is a timing one, so it survives amplitude errors that would ruin an
/// impedance reading. On a 2.97 m RG-58 it recovers the length to within a centimetre.
public struct CableMeasurement: Sendable, Hashable {
    /// Time for a signal to travel to the far end and back, in seconds.
    public var roundTripDelay: Double
    /// The reflection at the near junction — connector, adapter, the point the cable is
    /// screwed onto.
    public var nearReflection: Complex
    /// The reflection from the far end: whatever terminates the cable, plus its connector.
    public var farReflection: Complex
    /// RMS of what the two-reflection model failed to explain. Compare it against the
    /// size of the reflections themselves before trusting the result.
    public var residual: Double

    public init(roundTripDelay: Double, nearReflection: Complex, farReflection: Complex, residual: Double) {
        self.roundTripDelay = roundTripDelay
        self.nearReflection = nearReflection
        self.farReflection = farReflection
        self.residual = residual
    }

    public static let speedOfLight: Double = 299_792_458

    /// One-way length the signal would cover in free space during half the round trip.
    /// The cable's physical length is this times its velocity factor.
    public var electricalLength: Double { roundTripDelay * Self.speedOfLight / 2 }

    /// The cable's length, given how fast it propagates.
    public func physicalLength(velocityFactor: Double) -> Double {
        electricalLength * velocityFactor
    }

    /// How fast the cable propagates, given how long it is. The useful direction when the
    /// cable can be measured with a tape but its datasheet is unknown or untrusted.
    public func velocityFactor(physicalLength: Double) -> Double {
        guard electricalLength > 0 else { return 0 }
        return physicalLength / electricalLength
    }

    /// Whether the two-reflection model explains the data well enough to be believed.
    ///
    /// The threshold is set by what real measurements produce: a cable terminated in a
    /// load or a short leaves 1–4% of the reflection unexplained, while an antenna seen
    /// through a line leaves 35% — its far reflection is not one constant vector but
    /// something that swings with frequency, and the model has no way to say so. A cable
    /// measurement offered on an antenna sweep would be a confident wrong answer.
    public var isCredible: Bool {
        let signal = max(nearReflection.magnitude, farReflection.magnitude)
        return signal > 0.005 && residual < signal * 0.20
    }
}

public enum CableAnalyzer {
    /// Fits `Γ(f) = near + far · e^(-i·2π·f·τ)` to a sweep and returns the best τ.
    ///
    /// For any candidate delay the two reflections follow from a linear least squares, so
    /// only the delay has to be searched: a coarse scan at a fraction of the resolution
    /// the bandwidth can support, then a refinement around the best candidate.
    public static func measure(
        _ sweep: Sweep,
        minimumDelay: Double = 0.5e-9,
        maximumDelay: Double = 1e-6
    ) -> CableMeasurement? {
        let frequencies = sweep.points.map(\.frequency.hertz)
        guard frequencies.count >= 8,
              let lowest = frequencies.first,
              let highest = frequencies.last,
              highest > lowest
        else { return nil }

        let gammas = sweep.points.map {
            $0.reflection(referenceImpedance: sweep.referenceImpedance).complex
        }
        let bandwidth = highest - lowest

        // Beyond half the sampling rate in delay the interference aliases, and a longer
        // cable would be reported as a shorter one.
        let step = (frequencies.count > 1)
            ? (highest - lowest) / Double(frequencies.count - 1)
            : bandwidth
        let ceiling = min(maximumDelay, 1 / (2 * step))
        guard ceiling > minimumDelay else { return nil }

        let coarseStep = 1 / (20 * bandwidth)
        var best: (delay: Double, residual: Double)?
        var delay = minimumDelay
        while delay <= ceiling {
            let residual = fit(frequencies, gammas, delay: delay).residual
            if best == nil || residual < best!.residual { best = (delay, residual) }
            delay += coarseStep
        }
        guard var bestDelay = best?.delay else { return nil }

        // Ternary search inside the coarse bracket: the residual is smooth and unimodal
        // there, whatever it does across the whole range.
        var low = max(minimumDelay, bestDelay - coarseStep)
        var high = min(ceiling, bestDelay + coarseStep)
        for _ in 0..<80 {
            let third = (high - low) / 3
            let a = low + third
            let b = high - third
            if fit(frequencies, gammas, delay: a).residual < fit(frequencies, gammas, delay: b).residual {
                high = b
            } else {
                low = a
            }
        }
        bestDelay = (low + high) / 2

        let result = fit(frequencies, gammas, delay: bestDelay)
        return CableMeasurement(
            roundTripDelay: bestDelay,
            nearReflection: result.near,
            farReflection: result.far,
            residual: result.residual
        )
    }

    /// Least squares for the two reflections at a fixed delay.
    private static func fit(
        _ frequencies: [Double], _ gammas: [Complex], delay: Double
    ) -> (near: Complex, far: Complex, residual: Double) {
        let count = Double(frequencies.count)
        var sumRotor = Complex.zero
        var sumGamma = Complex.zero
        var sumGammaRotor = Complex.zero

        var rotors: [Complex] = []
        rotors.reserveCapacity(frequencies.count)
        for (frequency, gamma) in zip(frequencies, gammas) {
            let rotor = Complex.unit(angle: -2 * .pi * frequency * delay)
            rotors.append(rotor)
            sumRotor = sumRotor + rotor
            sumGamma = sumGamma + gamma
            sumGammaRotor = sumGammaRotor + gamma * rotor.conjugate
        }

        // The rotors have unit magnitude, so the diagonal of the normal equations is just
        // the sample count.
        let determinant = count * count - sumRotor.squaredMagnitude
        guard abs(determinant) > 1e-12 else {
            return (.zero, .zero, .infinity)
        }
        let near = (sumGamma * count - sumRotor * sumGammaRotor) / determinant
        let far = (sumGammaRotor * count - sumRotor.conjugate * sumGamma) / determinant

        var squared = 0.0
        for index in gammas.indices {
            squared += (gammas[index] - near - far * rotors[index]).squaredMagnitude
        }
        return (near, far, (squared / count).squareRoot())
    }
}
