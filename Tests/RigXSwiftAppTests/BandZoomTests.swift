import Foundation
import RigXCore
import Testing
@testable import RigXSwiftApp

@MainActor
@Suite("Zooming to a band")
struct BandZoomTests {
    /// A trace with two dips: a shallow one inside the Italian 4 m band, and a deeper one
    /// far outside it. Any readout that still describes the whole sweep while the charts
    /// show only 4 m will report the wrong one of the two.
    static func twoDips(from startMHz: Double = 1, to endMHz: Double = 170) -> AnalyzerModel.LoadedTrace {
        func resistance(at megahertz: Double) -> Double {
            // Purely resistive, so SWR is R/50 and the expected figures are exact.
            let inBand = notch(megahertz, centre: 70.2, halfWidth: 0.4, depth: 55)
            let outOfBand = notch(megahertz, centre: 30.0, halfWidth: 1.0, depth: 50.5)
            return Swift.min(inBand, outOfBand)
        }
        func notch(_ megahertz: Double, centre: Double, halfWidth: Double, depth: Double) -> Double {
            let distance = abs(megahertz - centre) / halfWidth
            return distance >= 1 ? 200 : depth + (200 - depth) * distance
        }

        // 100 kHz: coarse enough to keep the cable fit in these tests quick, fine
        // enough to put three samples inside a 200 kHz band.
        let step = 0.1
        let points = stride(from: startMHz, through: endMHz, by: step).map { megahertz in
            MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(resistance: resistance(at: megahertz), reactance: 0)
            )
        }
        return AnalyzerModel.LoadedTrace(
            name: "two dips", sweep: Sweep(name: "two dips", points: points), colorIndex: 1
        )
    }

    static func model(_ trace: AnalyzerModel.LoadedTrace) -> AnalyzerModel {
        let model = AnalyzerModel()
        model.bandPlan = .italy
        model.loadedTraces = [trace]
        model.selection = .loaded(trace.id)
        return model
    }

    static var fourMetres: AmateurBand {
        BandPlan.italy.band(at: .megahertz(70.2))!
    }

    @Test("The window and the samples both narrow to the band")
    func zoomNarrowsTheWindow() throws {
        let model = Self.model(Self.twoDips())
        let wide = try #require(model.frequencyWindow)
        #expect(wide.upperBound > 169)

        model.toggleZoom(to: Self.fourMetres)
        let window = try #require(model.frequencyWindow)
        #expect(window.lowerBound > 70 && window.upperBound < 70.4)
        #expect(!model.visiblePoints.isEmpty)
        #expect(model.visiblePoints.allSatisfy { window.contains($0.frequency.megahertz) })
        // The measurement itself is untouched: it is the view that narrowed.
        #expect(model.displayedPoints.count > model.visiblePoints.count)
    }

    @Test("The readouts describe the band, not the sweep it came from")
    func readoutsFollowTheZoom() throws {
        let model = Self.model(Self.twoDips())

        // Unzoomed, the deepest dip is the one at 30 MHz.
        let whole = try #require(model.minimumSWR)
        #expect(abs(whole.frequency.megahertz - 30) < 0.1)
        #expect(abs(whole.swr - 1.01) < 0.02)

        model.toggleZoom(to: Self.fourMetres)
        let inBand = try #require(model.minimumSWR)
        #expect(abs(inBand.frequency.megahertz - 70.2) < 0.1)
        #expect(abs(inBand.swr - 1.1) < 0.02)
        // And the marker on the chart is the sample that minimum was found at.
        let marker = try #require(model.bestMatch)
        #expect(abs(marker.frequency.megahertz - 70.2) < 0.1)
    }

    @Test("A zoom onto a band the trace never reaches is ignored")
    func zoomOutsideTheTraceIsIgnored() throws {
        // An HF-only sweep, and a band an octave above the top of it.
        let model = Self.model(Self.twoDips(from: 1, to: 30))
        let unzoomed = try #require(model.frequencyWindow)

        model.toggleZoom(to: Self.fourMetres)
        #expect(model.zoomRange == nil)
        #expect(model.frequencyWindow == unzoomed)
        #expect(model.visiblePoints.count == model.displayedPoints.count)
    }

    @Test("While a sweep is running the zoom waits for it to finish")
    func zoomWaitsForTheSweep() throws {
        let model = Self.model(Self.twoDips())
        model.toggleZoom(to: Self.fourMetres)
        #expect(model.zoomRange != nil)

        model.isSweeping = true
        #expect(model.zoomRange == nil)
        // Watching a 1–170 MHz measurement arrive means seeing all of it.
        #expect(try #require(model.frequencyWindow).upperBound > 169)

        model.isSweeping = false
        #expect(model.zoomRange != nil)
    }

    @Test("Clicking the band a second time zooms back out")
    func zoomToggles() {
        let model = Self.model(Self.twoDips())
        model.toggleZoom(to: Self.fourMetres)
        model.toggleZoom(to: Self.fourMetres)
        #expect(model.zoomedBand == nil)
        #expect(model.zoomRange == nil)
    }

    @Test("The cable analyses keep the whole measurement while the charts are zoomed")
    func analysesKeepTheirBandwidth() throws {
        let model = Self.model(AnalyzerModelTests.trace(named: "cable", delayNanoseconds: 20))
        let resolution = try #require(model.tdr).resolution
        let delay = try #require(model.cable).roundTripDelay

        model.toggleZoom(to: Self.fourMetres)

        // A 200 kHz slice cannot say anything about a cable — its time-domain resolution
        // would be hundreds of metres — so the zoom must not reach these.
        #expect(try #require(model.tdr).resolution == resolution)
        #expect(try #require(model.cable).roundTripDelay == delay)
        #expect(model.sweep?.points.count == model.displayedPoints.count)
    }
}
