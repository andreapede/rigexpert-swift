import Foundation

/// A stretch of a band given over to one kind of operating.
///
/// A simplification of the plan, and deliberately so. The IARU tables carry a maximum
/// bandwidth, an automatic-station flag and a dozen centres of activity per band; what
/// an antenna measurement needs is the coarse answer — is the dip where the voice is, or
/// where the digital modes are.
public struct BandSegment: Sendable, Hashable, Identifiable {
    public enum Mode: String, Sendable, Hashable, CaseIterable, Codable {
        /// Telegraphy.
        case cw
        /// The plan's "narrow band modes", plus the all-mode stretches its notes hand to
        /// digimodes — 1840–1843 on 160 m is where FT8 actually lives.
        case digital
        /// The plan's "all modes": SSB, AM and FM, which is where voice happens.
        case phone
        case beacon
        case satellite
    }

    public var mode: Mode
    public var range: ClosedRange<Frequency>

    public init(mode: Mode, range: ClosedRange<Frequency>) {
        self.mode = mode
        self.range = range
    }

    public var id: String { "\(mode.rawValue)@\(range.lowerBound.hertz)" }
    public var width: Frequency { .hertz(range.upperBound.hertz - range.lowerBound.hertz) }
}

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
    /// What the band is divided into, in frequency order and without overlaps. Empty
    /// where this project has no table for the plan — see `BandPlan`.
    public var segments: [BandSegment]

    public init(
        name: String,
        range: ClosedRange<Frequency>,
        isConditional: Bool = false,
        segments: [BandSegment] = []
    ) {
        self.name = name
        self.range = range
        self.isConditional = isConditional
        self.segments = segments
    }

    /// The range, not the name: 70 cm is two separate allocations in Italy, and both are
    /// called "70 cm".
    public var id: String { "\(name)@\(range.lowerBound.hertz)" }

    public var width: Frequency { .hertz(range.upperBound.hertz - range.lowerBound.hertz) }
    public var centre: Frequency { .hertz((range.lowerBound.hertz + range.upperBound.hertz) / 2) }

    public func contains(_ frequency: Frequency) -> Bool { range.contains(frequency) }

    /// Which kind of operating a frequency falls under. Nil in the gaps the plan leaves
    /// between segments, and everywhere in a plan with no segment table.
    public func segment(at frequency: Frequency) -> BandSegment? {
        segments.first { $0.range.contains(frequency) }
    }
}

extension ClosedRange where Bound == Frequency {
    /// The same range in megahertz, for the plotting layer.
    public var megahertz: ClosedRange<Double> { lowerBound.megahertz...upperBound.megahertz }
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

    /// The mode segments of the IARU Region 1 plans, by band name.
    ///
    /// Read from the two official tables, September 2026:
    ///   - IARU Region 1 HF Band Plan, effective 16 OCT 2020
    ///     iaru-r1.org/wp-content/uploads/2021/06/hf_r1_bandplan.pdf
    ///   - IARU Region 1 VHF Band Plan, effective December 2020
    ///     iaru-r1.org/wp-content/uploads/2020/12/VHF-Bandplan.pdf
    ///
    /// Reduced to four kinds of operating from the tables' own wording: "CW" is `cw`;
    /// "Narrow band modes" is `digital`, as are the all-mode stretches whose usage column
    /// says Digimodes; "All modes" is `phone`; the International Beacon Project and the
    /// coordinated beacon segments are `beacon`. Adjacent stretches of the same kind are
    /// merged — the plan's distinction between attended and automatic digital stations is
    /// real, and invisible on a chart of an antenna.
    ///
    /// Italy uses the same table: its bands are narrower, and the segments are clipped to
    /// them, which is exactly what the national plan does — 160 m in Italy is the CW,
    /// digimode and phone thirds of 1830–1850 and nothing above it.
    private typealias Span = (BandSegment.Mode, Double, Double)
    private static let region1Segments: [String: [Span]] = [
        "2200 m": [(.cw, 135.7, 137.8)],
        "630 m": [(.cw, 472, 475), (.digital, 475, 479)],
        "160 m": [(.cw, 1810, 1838), (.digital, 1838, 1843), (.phone, 1843, 2000)],
        "80 m": [(.cw, 3500, 3570), (.digital, 3570, 3600), (.phone, 3600, 3800)],
        // 5366.0–5366.5 is the plan's 20 Hz weak-signal slot: WSPR, in practice.
        "60 m": [(.cw, 5351.5, 5354), (.phone, 5354, 5366), (.digital, 5366, 5366.5)],
        "40 m": [(.cw, 7000, 7040), (.digital, 7040, 7060), (.phone, 7060, 7200)],
        "30 m": [(.cw, 10_100, 10_130), (.digital, 10_130, 10_150)],
        "20 m": [
            (.cw, 14_000, 14_070), (.digital, 14_070, 14_099),
            (.beacon, 14_099, 14_101), (.phone, 14_101, 14_350),
        ],
        "17 m": [
            (.cw, 18_068, 18_095), (.digital, 18_095, 18_109),
            (.beacon, 18_109, 18_111), (.phone, 18_111, 18_168),
        ],
        "15 m": [
            (.cw, 21_000, 21_070), (.digital, 21_070, 21_149),
            (.beacon, 21_149, 21_151), (.phone, 21_151, 21_450),
        ],
        "12 m": [
            (.cw, 24_890, 24_915), (.digital, 24_915, 24_929),
            (.beacon, 24_929, 24_931), (.phone, 24_931, 24_990),
        ],
        "10 m": [
            (.cw, 28_000, 28_070), (.digital, 28_070, 28_190),
            (.beacon, 28_190, 28_225), (.phone, 28_225, 29_200),
            (.digital, 29_200, 29_300), (.satellite, 29_300, 29_510),
            (.phone, 29_510, 29_700),
        ],
        "6 m": [
            (.cw, 50_000, 50_100), (.phone, 50_100, 50_300),
            (.digital, 50_300, 50_400), (.beacon, 50_400, 50_500),
            (.phone, 50_500, 52_000),
        ],
        // The whole of Italy's 4 m falls in the plan's narrow-band and FM stretches, so
        // it comes out as one block. That is the band: 200 kHz, and no room to divide.
        "4 m": [(.beacon, 70_000, 70_100), (.phone, 70_100, 70_500)],
        "2 m": [
            (.cw, 144_000, 144_150), (.phone, 144_150, 144_400),
            (.beacon, 144_400, 144_493), (.phone, 144_500, 144_794),
            (.digital, 144_794, 144_962.5), (.phone, 144_975, 145_794),
            (.satellite, 145_794, 146_000),
        ],
    ]

    /// A Region 1 band, with the plan's segments clipped to whatever the band's own edges
    /// are — which is how the Italian bands get their segments for free.
    private static func r1Band(
        _ name: String, _ lowKilohertz: Double, _ highKilohertz: Double, conditional: Bool = false
    ) -> AmateurBand {
        let range = Frequency.kilohertz(lowKilohertz)...Frequency.kilohertz(highKilohertz)
        let segments = (region1Segments[name] ?? []).compactMap { span -> BandSegment? in
            let low = Swift.max(span.1, lowKilohertz)
            let high = Swift.min(span.2, highKilohertz)
            guard high > low else { return nil }
            return BandSegment(mode: span.0, range: .kilohertz(low)...(.kilohertz(high)))
        }
        return AmateurBand(name: name, range: range, isConditional: conditional, segments: segments)
    }

    /// IARU Region 1: Europe, Africa, the Middle East and northern Asia.
    ///
    /// 160 m is drawn to 2000 kHz because the plan runs that far, and marked conditional
    /// because almost nowhere in the region may an operator use all of it — Italy stops
    /// at 1850.
    private static let region1Bands: [AmateurBand] = [
        r1Band("2200 m", 135.7, 137.8, conditional: true),
        r1Band("630 m", 472, 479, conditional: true),
        r1Band("160 m", 1810, 2000, conditional: true),
        r1Band("80 m", 3500, 3800),
        r1Band("60 m", 5351.5, 5366.5, conditional: true),
        r1Band("40 m", 7000, 7200),
        r1Band("30 m", 10_100, 10_150),
        r1Band("20 m", 14_000, 14_350),
        r1Band("17 m", 18_068, 18_168),
        r1Band("15 m", 21_000, 21_450),
        r1Band("12 m", 24_890, 24_990),
        r1Band("10 m", 28_000, 29_700),
        r1Band("6 m", 50_000, 52_000),
        r1Band("4 m", 70_000, 70_500, conditional: true),
        r1Band("2 m", 144_000, 146_000),
        r1Band("70 cm", 430_000, 440_000, conditional: true),
    ]

    /// Italy, as the PNRF allocates it.
    ///
    /// 160 m is 1830–1850: the 1810–1830 slice was only ever open under a temporary
    /// experimental authorisation. 4 m is 70.100–70.300, likewise experimental, which is
    /// why it is drawn as a conditional band and not as the region's 70.0–70.5.
    private static let italyBands: [AmateurBand] = [
        r1Band("2200 m", 135.7, 137.8, conditional: true),
        r1Band("630 m", 472, 479, conditional: true),
        r1Band("160 m", 1830, 1850),
        r1Band("80 m", 3500, 3800),
        r1Band("60 m", 5351.5, 5366.5, conditional: true),
        r1Band("40 m", 7000, 7200),
        r1Band("30 m", 10_100, 10_150),
        r1Band("20 m", 14_000, 14_350),
        r1Band("17 m", 18_068, 18_168),
        r1Band("15 m", 21_000, 21_450),
        r1Band("12 m", 24_890, 24_990),
        r1Band("10 m", 28_000, 29_700),
        r1Band("6 m", 50_000, 52_000),
        r1Band("4 m", 70_100, 70_300, conditional: true),
        r1Band("2 m", 144_000, 146_000),
        r1Band("70 cm", 430_000, 434_000, conditional: true),
        r1Band("70 cm", 435_000, 438_000, conditional: true),
    ]

    /// IARU Region 2: the Americas. The widest allocations of the three.
    ///
    /// Without mode segments: Regions 2 and 3 publish their own plans, and copying
    /// Region 1's onto them would be inventing a rule rather than reporting one. The
    /// interface says so rather than showing an empty strip.
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

    /// IARU Region 3: Asia-Pacific and Oceania. No mode segments, for the reason given
    /// above Region 2.
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
