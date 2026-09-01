import Foundation
import RigXCore
import RigXTransport
import Testing
@testable import RigXSwiftApp

/// A channel that identifies itself and then says nothing more.
///
/// Enough to get a session connected, and then to leave a sweep waiting — which is the
/// window in which the model's state has to stay coherent.
actor MuteAfterIdentifyChannel: ByteChannel {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func received() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { self.continuation = $0 }
    }

    func send(_ data: Data) async throws {
        if String(decoding: data, as: UTF8.self).contains("VER") {
            continuation?.yield(Data("AA-30.ZERO 200\r\n".utf8))
        }
    }

    func close() {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
@Suite("Analyzer model")
struct AnalyzerModelTests {
    /// A trace that looks like a cable: a small reflection at the plane and a larger one
    /// delayed by a round trip. Not an impedance made to wobble — the time-domain view
    /// needs something with an actual delay in it before it has anything to find.
    static func trace(
        named name: String,
        resistance: Double = 50,
        delayNanoseconds: Double = 20
    ) -> AnalyzerModel.LoadedTrace {
        let near = Complex(0.04 * (resistance / 50), 0)
        let far = Complex(0.35, 0)
        let points = (0...400).map { index -> MeasurementPoint in
            let megahertz = 1 + Double(index) * (169.0 / 400)
            let rotor = Complex.unit(angle: -2 * .pi * megahertz * 1e6 * delayNanoseconds * 1e-9)
            let gamma = near + far * rotor
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Reflection(gamma).impedance()
            )
        }
        return AnalyzerModel.LoadedTrace(
            name: name,
            sweep: Sweep(name: name, points: points),
            colorIndex: 1
        )
    }

    static func connectedModel(_ channel: @escaping @Sendable () -> any ByteChannel) async -> AnalyzerModel {
        let model = AnalyzerModel()
        // Never touch whatever calibration the machine running the tests happens to have.
        model.calibration = nil
        model.settleDelay = .zero
        model.makeChannel = { _, _ in channel() }
        model.selectedPort = "/dev/test"
        await model.connect()
        return model
    }

    @Test("Starting a sweep drops the analyses that described the previous trace")
    func analysesDoNotOutliveTheirTrace() async throws {
        let model = await Self.connectedModel { MuteAfterIdentifyChannel() }
        #expect(model.connection.isConnected)

        let loaded = Self.trace(named: "A", resistance: 60)
        model.loadedTraces = [loaded]
        model.selection = .loaded(loaded.id)
        model.recomputeCable()
        #expect(model.cable != nil, "the loaded trace has a cable measurement to lose")
        #expect(model.tdr != nil)

        // The analyzer answers the handshake and then goes quiet, so the sweep is still
        // in flight while these assertions run.
        let sweeping = Task { await model.runSweep() }
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.selection == .live, "the measurement being taken is the one to watch")
        #expect(model.cable == nil, "this described trace A, not the sweep now running")
        #expect(model.tdr == nil)
        #expect(model.sweep == nil, "nothing has been measured yet")

        sweeping.cancel()
        _ = await sweeping.value
    }

    @Test("A sweep that fails hands the window back, not to an older measurement")
    func failedSweepRestoresTheSelection() async throws {
        let model = await Self.connectedModel { SimulatedAnalyzerChannel() }

        // An earlier live measurement that must not resurface.
        let earlier = Sweep(
            name: "earlier",
            points: (0...20).map {
                MeasurementPoint(
                    frequency: .megahertz(1 + Double($0)),
                    impedance: Impedance(resistance: 12, reactance: -80)
                )
            }
        )
        model.rawSweep = earlier

        let loaded = Self.trace(named: "A", resistance: 60)
        model.loadedTraces = [loaded]
        model.selection = .loaded(loaded.id)

        // More points than any analyzer accepts: the simulator answers ERROR.
        model.points = 5000
        await model.runSweep()

        #expect(model.errorMessage != nil, "the failure has to be reported")
        #expect(model.selection == .loaded(loaded.id), "the operator's choice survives a failed sweep")
        #expect(model.sweep?.name == "A", "not the measurement from before")
        #expect(model.displayedPoints.count == loaded.sweep.points.count)
    }

    @Test("The frequency window covers every visible trace, not just the selected one")
    func windowSpansEverythingVisible() async throws {
        let model = await Self.connectedModel { SimulatedAnalyzerChannel() }
        let wide = Self.trace(named: "wide", resistance: 60)   // 1–170 MHz
        model.loadedTraces = [wide]

        // A narrower live measurement, of the kind that used to crop the file it was
        // being compared against.
        model.startMegahertz = 1
        model.endMegahertz = 30
        model.points = 40
        await model.runSweep()

        #expect(model.selection == .live)
        let window = try #require(model.frequencyWindow)
        #expect(window.upperBound > 169, "the wider file still has to fit: \(window)")
        #expect(window.lowerBound <= 1)

        // Hiding the wide trace hands the window back to the measurement alone.
        model.loadedTraces[0].isVisible = false
        let narrowed = try #require(model.frequencyWindow)
        #expect(narrowed.upperBound < 31, "nothing wide is visible any more: \(narrowed)")
    }

    @Test("A selected trace counts even when its visibility is switched off")
    func hiddenButSelectedTraceStillSetsTheWindow() async throws {
        // Hiding the selected trace removes it from the comparison overlay but not from
        // the chart: it is still the primary dataset. A window computed from the visible
        // traces alone therefore cropped the very trace being drawn.
        let model = AnalyzerModel()
        model.calibration = nil
        model.rawSweep = Sweep(
            name: "narrow",
            points: (0...30).map {
                MeasurementPoint(
                    frequency: .megahertz(1 + Double($0)),
                    impedance: Impedance(resistance: 45, reactance: 8)
                )
            }
        )

        let wide = Self.trace(named: "wide", resistance: 60)   // 1–170 MHz
        model.loadedTraces = [wide]
        model.selection = .loaded(wide.id)
        model.loadedTraces[0].isVisible = false

        #expect(model.displayedPoints.last?.frequency.megahertz == 170, "still the primary trace")
        let window = try #require(model.frequencyWindow)
        #expect(window.upperBound > 169, "the drawn trace cannot fall outside the axis: \(window)")
    }

    @Test("The selected trace cannot be hidden, because hiding it would do nothing")
    func selectedTraceCannotBeHidden() {
        let model = AnalyzerModel()
        model.calibration = nil
        let a = Self.trace(named: "A", resistance: 60)
        let b = Self.trace(named: "B", resistance: 40)
        model.loadedTraces = [a, b]

        model.selection = .loaded(a.id)
        #expect(!model.canHide(a.id), "it is the primary dataset and is drawn regardless")
        #expect(model.canHide(b.id))

        model.selection = .live
        #expect(model.canHide(a.id), "nothing loaded is primary now")
        #expect(model.canHide(b.id))
    }

    @Test("The stored analyses follow the selection, like the charts do")
    func analysesFollowTheSelection() throws {
        // The charts read a computed property and follow on their own; the cable and TDR
        // results are kept, and used to describe whichever trace was selected before.
        let model = AnalyzerModel()
        model.calibration = nil
        let short = Self.trace(named: "short", resistance: 60, delayNanoseconds: 10)
        let long = Self.trace(named: "long", resistance: 60, delayNanoseconds: 40)
        model.loadedTraces = [short, long]

        model.selection = .loaded(short.id)
        let firstTDR: TimeDomainResponse = try #require(model.tdr)
        let firstMeasurement: CableMeasurement = try #require(model.cable)
        let firstDistance = firstTDR.dominantDiscontinuity?.distance ?? 0
        let firstDelay = firstMeasurement.roundTripDelay

        model.selection = .loaded(long.id)
        let secondTDR: TimeDomainResponse = try #require(model.tdr)
        let secondMeasurement: CableMeasurement = try #require(model.cable)
        let secondDistance = secondTDR.dominantDiscontinuity?.distance ?? 0
        let secondDelay = secondMeasurement.roundTripDelay

        #expect(firstDistance > 0, "the shorter trace has a discontinuity to find")
        #expect(secondDistance > firstDistance * 2, "the TDR describes the trace now selected")
        #expect(secondDelay > firstDelay * 2, "and so does the cable measurement")
    }

    @Test("A sweep that succeeds shows itself")
    func successfulSweepBecomesVisible() async throws {
        let model = await Self.connectedModel { SimulatedAnalyzerChannel() }
        let loaded = Self.trace(named: "A", resistance: 60)
        model.loadedTraces = [loaded]
        model.selection = .loaded(loaded.id)

        model.startMegahertz = 1
        model.endMegahertz = 30
        model.points = 40
        await model.runSweep()

        #expect(model.errorMessage == nil)
        #expect(model.selection == .live)
        #expect(model.displayedPoints.count == 41, "N intervals, N+1 samples")
        #expect(model.loadedTraces.count == 1, "the loaded trace is still there")
    }
}
