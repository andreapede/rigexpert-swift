import Foundation

/// One amateur allocation, as a band plan draws it.
///
/// The overall edges only — the segments inside a band (CW, digital, phone, the beacon
/// windows) are an operating convention, and an antenna does not care about them. What
/// an antenna measurement needs to answer is "does the curve sit inside the band", and
/// that question is settled by the edges.
public struct AmateurBand: Sendable, Hashable, Identifiable {
    /// The wavelength name an operator uses: `"40 m"`, `"70 cm"`.
    public var name: String
    public var range: ClosedRange<Frequency>
    /// True when the band is not simply there for every holder of a licence: shared with
    /// a primary service, capped in power, split by national rules, or granted by an
    /// experimental authorisation that has to be renewed. Drawn fainter, because an
    /// antenna that covers it may still not be one you are allowed to transmit into.
    public var isConditional: Bool

    public init(name: String, range: ClosedRange<Frequency>, isConditional: Bool = false) {
        self.name = name
        self.range = range
        self.isConditional = isConditional
    }

    /// The range, not the name: 70 cm is two separate allocations in Italy, and both are
    /// called "70 cm".
    public var id: String { "\(name)@\(range.lowerBound.hertz)" }

    public var width: Frequency { .hertz(range.upperBound.hertz - range.lowerBound.hertz) }
    public var centre: Frequency { .hertz((range.lowerBound.hertz + range.upperBound.hertz) / 2) }

    public func contains(_ frequency: Frequency) -> Bool { range.contains(frequency) }
}

/// Where the bands are, according to whom.
///
/// Four plans rather than one: the amateur bands are not the same width everywhere, and
/// an overlay that draws 80 m as 3.5–4.0 MHz to a European reader would be telling them
/// they may transmit where they may not. The regional plans are the IARU's; `italy` is
/// what the national allocation actually permits, which is narrower again.
///
/// Sources, read September 2026:
///   - IARU Region 1 HF and VHF band plans, iaru-r1.org
///   - ITU regional allocations as tabulated at
///     en.wikipedia.org/wiki/Amateur_radio_frequency_allocations
///   - Italy: PNRF (Piano Nazionale di Ripartizione delle Frequenze) as published by
///     A.R.I., e.g. aritoscanasudest.it/bande-radio
///
/// Band edges move — 60 m and 4 m in particular are still being argued over country by
/// country. This table is a convenience, not a licence: the operator's own authority is.
public enum BandPlan: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    case italy
    case iaruRegion1
    case iaruRegion2
    case iaruRegion3

    public var id: Self { self }

    /// The first guess, and only that: the picker is one click away and the choice is
    /// kept. A Mac set to Italy gets the Italian plan; everything else gets Region 1,
    /// which is wrong for the Americas and the Pacific until its operator says so.
    public static var systemDefault: BandPlan {
        Locale.current.region?.identifier == "IT" ? .italy : .iaruRegion1
    }

    public var bands: [AmateurBand] {
        switch self {
        case .italy: Self.italyBands
        case .iaruRegion1: Self.region1Bands
        case .iaruRegion2: Self.region2Bands
        case .iaruRegion3: Self.region3Bands
        }
    }

    /// The bands that show inside a span, in frequency order.
    ///
    /// Overlap, not containment: a sweep from 28 to 29 MHz sits entirely inside 10 m and
    /// has to be told so, and a sweep from 1 to 30 MHz clips the bottom of 160 m without
    /// covering it.
    public func bands(overlapping range: ClosedRange<Frequency>) -> [AmateurBand] {
        bands.filter { $0.range.overlaps(range) }
    }

    /// The band a frequency falls in, when it falls in one.
    public func band(at frequency: Frequency) -> AmateurBand? {
        bands.first { $0.contains(frequency) }
    }

    private static func band(
        _ name: String, _ lowKilohertz: Double, _ highKilohertz: Double, conditional: Bool = false
    ) -> AmateurBand {
        AmateurBand(
            name: name,
            range: .kilohertz(lowKilohertz)...(.kilohertz(highKilohertz)),
            isConditional: conditional
        )
    }

    /// IARU Region 1: Europe, Africa, the Middle East and northern Asia.
    ///
    /// 160 m is drawn to 2000 kHz because the plan runs that far, and marked conditional
    /// because almost nowhere in the region may an operator use all of it — Italy stops
    /// at 1850.
    private static let region1Bands: [AmateurBand] = [
        band("2200 m", 135.7, 137.8, conditional: true),
        band("630 m", 472, 479, conditional: true),
        band("160 m", 1810, 2000, conditional: true),
        band("80 m", 3500, 3800),
        band("60 m", 5351.5, 5366.5, conditional: true),
        band("40 m", 7000, 7200),
        band("30 m", 10_100, 10_150),
        band("20 m", 14_000, 14_350),
        band("17 m", 18_068, 18_168),
        band("15 m", 21_000, 21_450),
        band("12 m", 24_890, 24_990),
        band("10 m", 28_000, 29_700),
        band("6 m", 50_000, 52_000),
        band("4 m", 70_000, 70_500, conditional: true),
        band("2 m", 144_000, 146_000),
        band("70 cm", 430_000, 440_000, conditional: true),
    ]

    /// Italy, as the PNRF allocates it.
    ///
    /// 160 m is 1830–1850: the 1810–1830 slice was only ever open under a temporary
    /// experimental authorisation. 4 m is 70.100–70.300, likewise experimental, which is
    /// why it is drawn as a conditional band and not as the region's 70.0–70.5.
    private static let italyBands: [AmateurBand] = [
        band("2200 m", 135.7, 137.8, conditional: true),
        band("630 m", 472, 479, conditional: true),
        band("160 m", 1830, 1850),
        band("80 m", 3500, 3800),
        band("60 m", 5351.5, 5366.5, conditional: true),
        band("40 m", 7000, 7200),
        band("30 m", 10_100, 10_150),
        band("20 m", 14_000, 14_350),
        band("17 m", 18_068, 18_168),
        band("15 m", 21_000, 21_450),
        band("12 m", 24_890, 24_990),
        band("10 m", 28_000, 29_700),
        band("6 m", 50_000, 52_000),
        band("4 m", 70_100, 70_300, conditional: true),
        band("2 m", 144_000, 146_000),
        band("70 cm", 430_000, 434_000, conditional: true),
        band("70 cm", 435_000, 438_000, conditional: true),
    ]

    /// IARU Region 2: the Americas. The widest allocations of the three.
    ///
    /// 60 m is five 2.8 kHz channels rather than a band; it is drawn as the span they
    /// occupy, which is why it is conditional. Shading five slivers on an HF-wide chart
    /// would draw nothing an eye could see.
    private static let region2Bands: [AmateurBand] = [
        band("2200 m", 135.7, 137.8, conditional: true),
        band("630 m", 472, 479, conditional: true),
        band("160 m", 1800, 2000),
        band("80 m", 3500, 4000),
        band("60 m", 5330.5, 5406.4, conditional: true),
        band("40 m", 7000, 7300),
        band("30 m", 10_100, 10_150),
        band("20 m", 14_000, 14_350),
        band("17 m", 18_068, 18_168),
        band("15 m", 21_000, 21_450),
        band("12 m", 24_890, 24_990),
        band("10 m", 28_000, 29_700),
        band("6 m", 50_000, 54_000),
        band("2 m", 144_000, 148_000),
        band("1.25 m", 222_000, 225_000, conditional: true),
        band("70 cm", 420_000, 450_000, conditional: true),
    ]

    /// IARU Region 3: Asia-Pacific and Oceania.
    private static let region3Bands: [AmateurBand] = [
        band("2200 m", 135.7, 137.8, conditional: true),
        band("630 m", 472, 479, conditional: true),
        band("160 m", 1800, 2000, conditional: true),
        band("80 m", 3500, 3900),
        band("60 m", 5351.5, 5366.5, conditional: true),
        band("40 m", 7000, 7200),
        band("30 m", 10_100, 10_150),
        band("20 m", 14_000, 14_350),
        band("17 m", 18_068, 18_168),
        band("15 m", 21_000, 21_450),
        band("12 m", 24_890, 24_990),
        band("10 m", 28_000, 29_700),
        band("6 m", 50_000, 54_000),
        band("2 m", 144_000, 148_000),
        band("70 cm", 430_000, 450_000, conditional: true),
    ]
}

/// What one sweep has to say about one band.
public struct BandSummary: Sendable, Hashable, Identifiable {
    public var band: AmateurBand
    /// How much of the band the sweep spans, 0…1. A partial figure is the warning that
    /// the best SWR below belongs to the part that was measured, not to the band.
    public var coverage: Double
    /// Samples that landed inside the band. Zero is possible with a coarse grid over a
    /// narrow band — 30 m is 50 kHz wide, and a 1–30 MHz sweep in 200 steps has a
    /// 145 kHz grid — and is the honest reason for an empty readout.
    public var sampleCount: Int
    /// Samples inside the band the analyzer could not measure, |Γ| ≥ 1. They are left
    /// out of the figures below, so a band full of them reads as empty rather than good.
    public var faultCount: Int
    public var minimumSWR: Double?
    public var frequencyOfMinimum: Frequency?
    /// The worst SWR inside the band: whether the antenna covers the band, as against
    /// merely touching it somewhere.
    public var worstSWR: Double?

    public var id: String { band.id }

    /// True when the sweep only reaches part of the band.
    public var isPartial: Bool { coverage < 0.999 }
}

extension Sweep {
    /// Every band of a plan the sweep says something about, in frequency order.
    public func bandSummaries(for plan: BandPlan) -> [BandSummary] {
        guard let span = frequencyRange else { return [] }
        let z0 = referenceImpedance
        return plan.bands(overlapping: span).map { band in
            let inBand = points.filter { band.contains($0.frequency) }
            let swrs = inBand.compactMap { $0.reflection(referenceImpedance: z0).swr }
            let overlap = Swift.min(span.upperBound.hertz, band.range.upperBound.hertz)
                - Swift.max(span.lowerBound.hertz, band.range.lowerBound.hertz)

            let minimum = Sweep(name: band.name, referenceImpedance: z0, points: inBand).minimumSWR
            return BandSummary(
                band: band,
                coverage: band.width.hertz > 0 ? Swift.max(0, overlap) / band.width.hertz : 0,
                sampleCount: inBand.count,
                faultCount: inBand.count - swrs.count,
                // From the refined minimum, not from the lowest sample: over a 50 kHz
                // band a grid step can be wider than the band, and the sample nearest
                // the dip is not the dip.
                minimumSWR: minimum?.swr,
                frequencyOfMinimum: minimum.map(\.frequency),
                worstSWR: swrs.max()
            )
        }
    }
}
