import Accelerate
import Foundation

/// How the measured band is tapered before transforming.
///
/// A sweep is a spectrum cut off abruptly at both ends, and transforming it as-is rings:
/// the truncation produces sidelobes that look exactly like extra discontinuities along
/// the cable. A window suppresses them, at the cost of widening the main lobe — which is
/// to say, at the cost of resolution. There is no setting that avoids the trade; the
/// honest thing is to name it.
public enum TDRWindow: String, CaseIterable, Sendable, Codable {
    case none
    case hann
    case hamming
    case blackman

    public var name: String {
        switch self {
        case .none: "nessuna"
        case .hann: "Hann"
        case .hamming: "Hamming"
        case .blackman: "Blackman"
        }
    }

    /// How much wider the main lobe becomes, and therefore how much the resolution
    /// worsens. Ratios of the -3 dB main-lobe width to the rectangular case.
    public var resolutionPenalty: Double {
        switch self {
        case .none: 1.0
        case .hann: 1.62
        case .hamming: 1.47
        case .blackman: 1.90
        }
    }

    func weight(_ index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        let x = Double(index) / Double(count - 1)
        switch self {
        case .none: return 1
        case .hann: return 0.5 - 0.5 * cos(2 * .pi * x)
        case .hamming: return 0.54 - 0.46 * cos(2 * .pi * x)
        case .blackman: return 0.42 - 0.5 * cos(2 * .pi * x) + 0.08 * cos(4 * .pi * x)
        }
    }
}

/// What a sweep looks like along the cable instead of across frequency.
public struct TimeDomainResponse: Sendable {
    /// One-way distance from the reference plane, in metres.
    public var distances: [Double]
    /// Reflection against distance: discontinuities appear as peaks.
    public var impulse: [Double]
    /// The running sum of the impulse response, which is the reflection a step would see.
    public var step: [Double]
    /// The step response read as an impedance profile, in ohms.
    public var impedance: [Double]

    /// The smallest separation two discontinuities can have and still be told apart.
    /// Set by the measured bandwidth and made worse by the window.
    public var resolution: Double
    /// Beyond this the response wraps around and a far fault appears as a near one.
    public var unambiguousRange: Double
    public var window: TDRWindow
    public var velocityFactor: Double
    public var referenceImpedance: Double

    /// The strongest discontinuity past the reference plane.
    public var dominantDiscontinuity: (distance: Double, magnitude: Double)? {
        // Skip the first few bins: the plane itself always shows something.
        let start = max(1, Int((resolution / 2) / max(distanceStep, 1e-9)))
        guard start < impulse.count else { return nil }
        let range = start..<impulse.count
        guard let index = range.max(by: { abs(impulse[$0]) < abs(impulse[$1]) }) else { return nil }
        return (distances[index], abs(impulse[index]))
    }

    /// Spacing of the distance axis. Finer than the resolution: the transform produces
    /// more samples than it can actually distinguish.
    public var distanceStep: Double { distances.count > 1 ? distances[1] - distances[0] : 0 }
}

public enum TimeDomain {
    /// Transforms a sweep into a picture of the line.
    ///
    /// - Parameter velocityFactor: how fast the cable propagates. The transform works in
    ///   time; turning time into distance needs this number, and getting it wrong scales
    ///   the whole axis.
    public static func transform(
        _ sweep: Sweep,
        velocityFactor: Double,
        window: TDRWindow = .hann
    ) -> TimeDomainResponse? {
        let points = sweep.points
        guard points.count >= 8, velocityFactor > 0 else { return nil }

        let frequencies = points.map(\.frequency.hertz)
        let spacing = (frequencies[frequencies.count - 1] - frequencies[0]) / Double(frequencies.count - 1)
        guard spacing > 0 else { return nil }

        // The transform needs a uniform grid; refuse rather than silently resample a
        // sweep that is not one.
        for index in 1..<frequencies.count {
            let gap = frequencies[index] - frequencies[index - 1]
            guard abs(gap - spacing) < spacing * 0.05 else { return nil }
        }

        let gammas = points.map {
            $0.reflection(referenceImpedance: sweep.referenceImpedance).complex
        }

        // Rebuild the spectrum from DC. The measurement starts somewhere above it, and
        // the missing bins have to be filled: leaving them at zero puts a step at the
        // start of the record and tilts everything after it.
        let firstBin = Int((frequencies[0] / spacing).rounded())
        let highestBin = firstBin + frequencies.count - 1
        var spectrum = [Complex](repeating: .zero, count: highestBin + 1)
        for (offset, gamma) in gammas.enumerated() {
            spectrum[firstBin + offset] = gamma
        }
        if firstBin > 0 {
            // Γ at zero frequency is real — a network of real components cannot have a
            // phase there — so extrapolate the first two measured bins back to DC and
            // keep only the real part, then bridge the gap linearly.
            let slope = gammas.count > 1 ? gammas[1] - gammas[0] : Complex.zero
            let extrapolated = gammas[0] - slope * Double(firstBin)
            let atDC = Complex(extrapolated.real, 0)
            for bin in 0..<firstBin {
                let fraction = Double(bin) / Double(firstBin)
                spectrum[bin] = atDC.interpolated(to: gammas[0], at: fraction)
            }
        }

        // Taper only the measured part; the extrapolated bins are already a guess.
        for offset in 0..<gammas.count {
            spectrum[firstBin + offset] = spectrum[firstBin + offset]
                * window.weight(offset, count: gammas.count)
        }

        // A real time-domain record needs a Hermitian spectrum.
        var size = 1
        while size < (spectrum.count * 2) { size <<= 1 }
        var real = [Double](repeating: 0, count: size)
        var imaginary = [Double](repeating: 0, count: size)
        for (bin, value) in spectrum.enumerated() {
            real[bin] = value.real
            imaginary[bin] = value.imaginary
            if bin > 0 {
                real[size - bin] = value.real
                imaginary[size - bin] = -value.imaginary
            }
        }

        guard let dft = try? vDSP.DiscreteFourierTransform(
            previous: nil, count: size, direction: .inverse,
            transformType: .complexComplex, ofType: Double.self
        ) else { return nil }
        let result = dft.transform(real: real, imaginary: imaginary)

        // vDSP's inverse leaves the 1/N out; with it in, the running sum of the impulse
        // response converges to Γ at DC, which is what makes the step response readable
        // as an impedance.
        let scale = 1.0 / Double(size)
        let halfLength = size / 2
        let timeStep = 1 / (Double(size) * spacing)
        let metresPerSample = CableMeasurement.speedOfLight * velocityFactor * timeStep / 2

        var impulse = [Double](repeating: 0, count: halfLength)
        var distances = [Double](repeating: 0, count: halfLength)
        var step = [Double](repeating: 0, count: halfLength)
        var impedance = [Double](repeating: 0, count: halfLength)

        var running = 0.0
        for index in 0..<halfLength {
            let value = result.real[index] * scale
            impulse[index] = value
            running += value
            step[index] = running
            distances[index] = Double(index) * metresPerSample
            // Γ of exactly ±1 is a short or an open; clamp just inside so the impedance
            // stays a number instead of running to infinity on a single noisy sample.
            let rho = min(max(running, -0.999), 0.999)
            impedance[index] = sweep.referenceImpedance * (1 + rho) / (1 - rho)
        }

        let bandwidth = frequencies[frequencies.count - 1] - frequencies[0]
        return TimeDomainResponse(
            distances: distances,
            impulse: impulse,
            step: step,
            impedance: impedance,
            resolution: CableMeasurement.speedOfLight * velocityFactor
                / (2 * bandwidth) * window.resolutionPenalty,
            unambiguousRange: CableMeasurement.speedOfLight * velocityFactor / (2 * spacing),
            window: window,
            velocityFactor: velocityFactor,
            referenceImpedance: sweep.referenceImpedance
        )
    }
}
