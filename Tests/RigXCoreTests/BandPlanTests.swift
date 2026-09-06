import Foundation
import Testing
@testable import RigXCore

@Suite("Amateur band plans")
struct BandPlanTests {
    /// A sweep whose reactance passes through zero at one frequency, with the resistance
    /// held at the system impedance — so the SWR minimum is exactly 1 and exactly there.
    static func resonant(
        at resonanceMHz: Double, from startMHz: Double, to endMHz: Double, points: Int = 500
    ) -> Sweep {
        let samples = (0...points).map { index -> MeasurementPoint in
            let megahertz = startMHz + (endMHz - startMHz) * Double(index) / Double(points)
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(resistance: 50, reactance: (megahertz - resonanceMHz) * 60)
            )
        }
        return Sweep(name: "resonant", points: samples)
    }

    @Test("Every plan is a set of ordered, non-overlapping allocations", arguments: BandPlan.allCases)
    func plansAreWellFormed(plan: BandPlan) throws {
        let bands = plan.bands
        #expect(!bands.isEmpty)
        for band in bands {
            #expect(band.range.lowerBound < band.range.upperBound, "\(plan) \(band.name) is empty")
        }
        for (earlier, later) in zip(bands, bands.dropFirst()) {
            // Sorted, and disjoint: `band(at:)` returns the first match, so an overlap
            // would make the answer depend on the order of the table.
            #expect(
                earlier.range.upperBound < later.range.lowerBound,
                "\(plan): \(earlier.name) runs into \(later.name)"
            )
        }
    }

    @Test("A band is chosen when the sweep touches it, not only when it covers it")
    func overlapNotContainment() {
        let plan = BandPlan.italy
        // Entirely inside 10 m.
        #expect(plan.bands(overlapping: .megahertz(28.2)...(.megahertz(28.4))).map(\.name) == ["10 m"])
        // Clips the bottom of 160 m without reaching its top.
        #expect(plan.bands(overlapping: .megahertz(1)...(.megahertz(1.84))).map(\.name) == ["160 m"])
        // Between two bands.
        #expect(plan.bands(overlapping: .megahertz(8)...(.megahertz(9))).isEmpty)
    }

    @Test("The Italian plan is narrower than the region it belongs to")
    func italyIsNarrowerThanRegion1() throws {
        let italy = try #require(BandPlan.italy.band(at: .kilohertz(1840)))
        let region1 = try #require(BandPlan.iaruRegion1.band(at: .kilohertz(1840)))
        #expect(italy.name == "160 m" && region1.name == "160 m")
        // 1810–1830 was only ever open under a temporary authorisation, and 1850–2000
        // is not Italy's at all.
        #expect(italy.range.upperBound < region1.range.upperBound)
        #expect(BandPlan.italy.band(at: .kilohertz(1900)) == nil)
        #expect(BandPlan.iaruRegion1.band(at: .kilohertz(1900)) != nil)

        // 4 m: 70.100–70.300 in Italy against the region's 70.0–70.5.
        #expect(BandPlan.italy.band(at: .megahertz(70.05)) == nil)
        #expect(BandPlan.iaruRegion1.band(at: .megahertz(70.05))?.name == "4 m")
    }

    @Test("The regions differ where the allocations do")
    func regionsDiffer() {
        // 80 m stops at 3.8 in Region 1, runs to 4.0 in Region 2.
        #expect(BandPlan.iaruRegion1.band(at: .megahertz(3.9)) == nil)
        #expect(BandPlan.iaruRegion2.band(at: .megahertz(3.9))?.name == "80 m")
        // 6 m stops at 52 in Region 1 and runs to 54 in Regions 2 and 3.
        #expect(BandPlan.iaruRegion1.band(at: .megahertz(53)) == nil)
        #expect(BandPlan.iaruRegion2.band(at: .megahertz(53))?.name == "6 m")
        #expect(BandPlan.iaruRegion3.band(at: .megahertz(53))?.name == "6 m")
    }

    @Test("The summary finds the dip and says which band it is in")
    func summaryFindsTheDip() throws {
        let sweep = Self.resonant(at: 14.15, from: 1, to: 30)
        let summaries = sweep.bandSummaries(for: .italy)
        let twenty = try #require(summaries.first { $0.band.name == "20 m" })

        let minimum = try #require(twenty.minimumSWR)
        // Not 1.000: |Γ| rises linearly either side of this resonance, and the parabola
        // the refinement fits through a V undershoots its vertex. Close enough is the
        // claim being made here — that the dip was found and attributed to 20 m.
        #expect(minimum < 1.05)
        let frequency = try #require(twenty.frequencyOfMinimum)
        #expect(abs(frequency.megahertz - 14.15) < 0.01)
        // The sweep spans the whole band, and every sample in it was measurable.
        #expect(abs(twenty.coverage - 1) < 1e-9)
        #expect(!twenty.isPartial)
        #expect(twenty.faultCount == 0)
        #expect(twenty.sampleCount > 0)

        // And every other band it crosses is nothing like matched.
        let fifteen = try #require(summaries.first { $0.band.name == "15 m" })
        #expect(try #require(fifteen.minimumSWR) > 10)
    }

    @Test("A band the sweep only reaches into is reported as partial")
    func partialCoverage() throws {
        // 20 m runs 14.000–14.350; this stops 150 kHz in.
        let sweep = Self.resonant(at: 14.1, from: 1, to: 14.15)
        let twenty = try #require(sweep.bandSummaries(for: .italy).first { $0.band.name == "20 m" })
        #expect(twenty.isPartial)
        #expect(abs(twenty.coverage - 0.15 / 0.35) < 0.01)
    }

    @Test("A band the grid steps over reports nothing rather than something")
    func noSamplesInBand() throws {
        // 30 m is 50 kHz wide; ten steps over 1–30 MHz are 2.9 MHz apart.
        let sweep = Self.resonant(at: 14.15, from: 1, to: 30, points: 10)
        let thirty = try #require(sweep.bandSummaries(for: .italy).first { $0.band.name == "30 m" })
        #expect(thirty.sampleCount == 0)
        #expect(thirty.minimumSWR == nil)
        #expect(thirty.worstSWR == nil)
        // The band is still spanned by the sweep — it is the grid that missed it, and
        // that is what the readout has to be able to say.
        #expect(abs(thirty.coverage - 1) < 1e-9)
    }

    @Test("Samples the analyzer could not measure are counted, not averaged in")
    func faultsAreCounted() throws {
        var sweep = Self.resonant(at: 14.15, from: 14, to: 14.35, points: 100)
        // |Γ| ≥ 1: a passive load cannot do this, and it is what the analyzer reports
        // when it fails to measure.
        sweep.points[10].impedance = Impedance(resistance: -5, reactance: 0)
        let twenty = try #require(sweep.bandSummaries(for: .italy).first { $0.band.name == "20 m" })
        #expect(twenty.faultCount == 1)
        #expect(twenty.sampleCount == 101)
        #expect(try #require(twenty.worstSWR).isFinite)
    }
}

@Suite("Mode segments")
struct BandSegmentTests {
    /// The plans whose segments this project tabulates. Regions 2 and 3 publish their own
    /// and are deliberately left empty.
    static let segmentedPlans: [BandPlan] = [.italy, .iaruRegion1]

    @Test("Segments are ordered, disjoint, and inside their band", arguments: segmentedPlans)
    func segmentsAreWellFormed(plan: BandPlan) {
        for band in plan.bands {
            for segment in band.segments {
                #expect(segment.range.lowerBound < segment.range.upperBound)
                #expect(
                    band.range.lowerBound <= segment.range.lowerBound
                        && segment.range.upperBound <= band.range.upperBound,
                    "\(plan) \(band.name): \(segment.mode) escapes the band"
                )
            }
            for (earlier, later) in zip(band.segments, band.segments.dropFirst()) {
                // `segment(at:)` returns the first match, so an overlap would make the
                // answer depend on the order of the table.
                #expect(
                    earlier.range.upperBound <= later.range.lowerBound,
                    "\(plan) \(band.name): \(earlier.mode) runs into \(later.mode)"
                )
            }
        }
    }

    @Test("Every HF band an antenna is cut for is divided up")
    func hfBandsHaveSegments() throws {
        for name in ["160 m", "80 m", "40 m", "30 m", "20 m", "17 m", "15 m", "12 m", "10 m"] {
            let band = try #require(BandPlan.italy.bands.first { $0.name == name })
            #expect(!band.segments.isEmpty, "\(name) has no segments")
        }
    }

    @Test("The well known frequencies land where they should")
    func knownFrequencies() throws {
        let twenty = try #require(BandPlan.italy.band(at: .megahertz(14.2)))
        #expect(twenty.segment(at: .megahertz(14.020))?.mode == .cw)
        // FT8 and its neighbours.
        #expect(twenty.segment(at: .megahertz(14.074))?.mode == .digital)
        #expect(twenty.segment(at: .megahertz(14.100))?.mode == .beacon)
        #expect(twenty.segment(at: .megahertz(14.200))?.mode == .phone)

        let forty = try #require(BandPlan.italy.band(at: .megahertz(7.1)))
        #expect(forty.segment(at: .megahertz(7.030))?.mode == .cw)
        #expect(forty.segment(at: .megahertz(7.045))?.mode == .digital)
        #expect(forty.segment(at: .megahertz(7.100))?.mode == .phone)

        // 160 m: the plan hands 1840–1843 to digimodes even though it is an all-mode
        // segment, which is where FT8 actually sits.
        let onesixty = try #require(BandPlan.iaruRegion1.band(at: .megahertz(1.84)))
        #expect(onesixty.segment(at: .megahertz(1.840))?.mode == .digital)
        #expect(onesixty.segment(at: .megahertz(1.850))?.mode == .phone)
    }

    @Test("Italy gets the region's segments, cut to Italy's band")
    func italianSegmentsAreClipped() throws {
        let italy = try #require(BandPlan.italy.band(at: .kilohertz(1840)))
        let region1 = try #require(BandPlan.iaruRegion1.band(at: .kilohertz(1840)))

        #expect(italy.segments.map(\.mode) == [.cw, .digital, .phone])
        #expect(italy.segments.map(\.mode) == region1.segments.map(\.mode))
        // Same kinds, but the Italian phone segment stops where the Italian band does.
        let italianPhone = try #require(italy.segments.last)
        let regionPhone = try #require(region1.segments.last)
        #expect(italianPhone.range.upperBound == .kilohertz(1850))
        #expect(regionPhone.range.upperBound == .kilohertz(2000))
        // And the CW segment starts at the Italian edge, not at the region's 1810.
        let italianCW = try #require(italy.segments.first)
        #expect(italianCW.range.lowerBound == .kilohertz(1830))
    }

    @Test("Regions 2 and 3 carry no segments rather than Region 1's", arguments: [BandPlan.iaruRegion2, .iaruRegion3])
    func otherRegionsHaveNone(plan: BandPlan) {
        #expect(plan.bands.allSatisfy { $0.segments.isEmpty })
        #expect(plan.band(at: .megahertz(14.074))?.segment(at: .megahertz(14.074)) == nil)
    }
}
