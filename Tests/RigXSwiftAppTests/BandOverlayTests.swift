import Foundation
import RigXCore
import Testing
@testable import RigXSwiftApp

@Suite("Band labels on the chart")
struct BandOverlayTests {
    /// The estimate the layout itself uses, so a test asserting "these do not overlap"
    /// is asking about the same rectangles the chart draws.
    static func labelWidth(_ name: String) -> Double { Double(name.count) * 5.5 + 6 }

    @Test("No two names are drawn on top of each other")
    func namesDoNotCollide() {
        // The case that motivates the whole layout: eleven HF bands across a sweep wide
        // enough that 30 m, 17 m and 12 m are a few pixels each.
        let span = 1.0...170.0
        let bands = BandPlan.italy.bands(overlapping: .megahertz(1)...(.megahertz(170)))
        let placements = BandLabelLayout.placements(for: bands, span: span, width: 800)

        for (earlier, later) in zip(placements, placements.dropFirst()) {
            let gap = later.x - earlier.x
            let needed = (Self.labelWidth(earlier.band.name) + Self.labelWidth(later.band.name)) / 2
            #expect(gap >= needed, "\(earlier.band.name) and \(later.band.name) overlap")
        }
        #expect(!placements.isEmpty)
        // And what does get drawn is in frequency order, left to right.
        #expect(placements.map(\.x) == placements.map(\.x).sorted())
    }

    @Test("When only one name fits, it is the wider band's")
    func theWiderBandKeepsItsName() throws {
        // 10 m is 1.7 MHz wide, 12 m is 100 kHz. Forty points of chart hold one label
        // of about twenty-eight, so only one of the two names can be drawn.
        let bands = BandPlan.italy.bands(overlapping: .megahertz(24.8)...(.megahertz(29.8)))
        #expect(bands.map(\.name) == ["12 m", "10 m"])

        let placements = BandLabelLayout.placements(for: bands, span: 24.8...29.8, width: 40)
        #expect(placements.map(\.band.name) == ["10 m"])
    }

    @Test("A band at the edge of the sweep is nudged inside, not dropped")
    func edgeBandIsKept() throws {
        // 20 m starts at 14.000 and the sweep starts inside it, so the band's true centre
        // is off the left of the chart.
        let bands = BandPlan.italy.bands(overlapping: .megahertz(14.2)...(.megahertz(14.3)))
        let placements = BandLabelLayout.placements(for: bands, span: 14.2...14.3, width: 400)

        let twenty = try #require(placements.first)
        #expect(twenty.band.name == "20 m")
        #expect(twenty.x >= Self.labelWidth("20 m") / 2)
        #expect(twenty.x <= 400 - Self.labelWidth("20 m") / 2)
    }

    @Test("A band too narrow to see is widened to a sliver, a wide one is left alone")
    func slendersBandsStayVisible() throws {
        let span = 1.0...170.0
        let thirty = try #require(BandPlan.italy.band(at: .megahertz(10.12)))
        let drawn = BandLabelLayout.drawnRange(for: thirty, in: span)
        // 50 kHz over a 169 MHz span is three ten-thousandths of the width: at any
        // sensible chart size that rectangle rounds away to nothing.
        #expect(drawn.upperBound - drawn.lowerBound > thirty.width.megahertz)
        #expect(abs((drawn.lowerBound + drawn.upperBound) / 2 - thirty.centre.megahertz) < 1e-9)

        let ten = try #require(BandPlan.italy.band(at: .megahertz(28.5)))
        let untouched = BandLabelLayout.drawnRange(for: ten, in: span)
        #expect(untouched.lowerBound == ten.range.lowerBound.megahertz)
        #expect(untouched.upperBound == ten.range.upperBound.megahertz)
    }

    @Test("Nothing is placed on a chart with no width")
    func degenerateChart() {
        let bands = BandPlan.italy.bands
        #expect(BandLabelLayout.placements(for: bands, span: 1...30, width: 0).isEmpty)
        #expect(BandLabelLayout.placements(for: bands, span: 30...30, width: 500).isEmpty)
    }
}
