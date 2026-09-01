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
    static func trace(named name: String, resistance: Double) -> AnalyzerModel.LoadedTrace {
        // A line into a mismatch: enough structure for the cable and TDR analyses to
        // find something, so their disappearance is observable.
        let points = (0...400).map { index -> MeasurementPoint in
            let megahertz = 1 + Double(index) * (169.0 / 400)
            let phase = 2 * Double.pi * megahertz * 1e6 * 20e-9
            return MeasurementPoint(
                frequency: .megahertz(megahertz),
                impedance: Impedance(
                    resistance: resistance + 20 * cos(phase),
                    reactance: 30 * sin(phase)
                )
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
