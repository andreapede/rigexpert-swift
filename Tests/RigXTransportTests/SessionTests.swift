import RigXCore
import Foundation
import Testing
@testable import RigXTransport

@Suite("Analyzer session")
struct AnalyzerSessionTests {
    @Test("The analyzer identifies itself over the wire")
    func identify() async throws {
        let session = AnalyzerSession(channel: SimulatedAnalyzerChannel())
        await session.start()

        let version = try await session.identify()
        #expect(version.model == "AA-30 ZERO")
        #expect(version.firmware == "100")
        #expect(version.profile?.frequencyRange.upperBound == .megahertz(30))
        await session.stop()
    }

    @Test("A full sweep completes and carries the requested number of points")
    func sweep() async throws {
        let channel = SimulatedAnalyzerChannel(
            impedance: Impedance(resistance: 75, reactance: -25)
        )
        let session = AnalyzerSession(channel: channel)
        await session.start()

        let sweep = try await session.sweep(
            from: .megahertz(1), to: .megahertz(30), points: 200, name: "Dipolo"
        )

        #expect(sweep.name == "Dipolo")
        // N intervals means N+1 samples, both ends included.
        #expect(sweep.points.count == 201)
        #expect(sweep.points.first?.frequency == .megahertz(1))
        #expect(abs(sweep.points.last!.frequency.megahertz - 30) < 1e-6)

        // The derived parameters have to survive the whole round trip intact.
        let gamma = sweep.points[0].reflection()
        #expect(abs(gamma.swr! - 1.7676) < 1e-3)
        await session.stop()
    }

    @Test("Sweeping the AA-30 ZERO's full range works end to end")
    func fullRangeSweep() async throws {
        let profile = DeviceProfile.profile(named: "AA-30 ZERO")!
        let session = AnalyzerSession(channel: SimulatedAnalyzerChannel())
        await session.start()

        let sweep = try await session.sweep(
            from: profile.frequencyRange.lowerBound,
            to: profile.frequencyRange.upperBound,
            points: 500
        )
        #expect(sweep.points.count == 501)
        #expect(sweep.points.first?.frequency.kilohertz == 60)
        #expect(sweep.bestMatch != nil)
        await session.stop()
    }

    @Test("Chunk boundaries that split lines do not lose points", arguments: [1, 3, 17, 64, 4096])
    func arbitraryChunking(chunkSize: Int) async throws {
        // The simulator emits in fixed-size chunks that deliberately fall in the middle
        // of lines, which is what a real serial port does.
        let session = AnalyzerSession(channel: SimulatedAnalyzerChannel(chunkSize: chunkSize))
        await session.start()
        let sweep = try await session.sweep(from: .megahertz(1), to: .megahertz(10), points: 50)
        #expect(sweep.points.count == 51)
        await session.stop()
    }

    @Test("An analyzer that says nothing eventually times out")
    func timeout() async throws {
        let session = AnalyzerSession(channel: SilentChannel())
        await session.start()
        await session.setReplyTimeout(.milliseconds(100))

        await #expect(throws: AnalyzerSession.SessionError.self) {
            try await session.identify()
        }
        await session.stop()
    }

    @Test("A sweep the analyzer rejects surfaces as an error, not a hang")
    func analyzerError() async throws {
        let session = AnalyzerSession(channel: SimulatedAnalyzerChannel())
        await session.start()
        await session.setReplyTimeout(.seconds(1))

        // More points than any RigExpert analyzer accepts.
        await #expect(throws: AnalyzerSession.SessionError.analyzerReportedError) {
            try await session.sweep(from: .megahertz(1), to: .megahertz(2), points: 5000)
        }
        await session.stop()
    }

    @Test("An empty sweep is refused before anything reaches the analyzer")
    func zeroPoints() async throws {
        let session = AnalyzerSession(channel: SimulatedAnalyzerChannel())
        await session.start()
        await #expect(throws: AnalyzerSession.SessionError.invalidPointCount(0)) {
            try await session.sweep(from: .megahertz(1), to: .megahertz(2), points: 0)
        }
        await session.stop()
    }
}

/// A channel that connects to nothing and never answers.
actor SilentChannel: ByteChannel {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func received() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { self.continuation = $0 }
    }

    func send(_ data: Data) async throws {}

    func close() {
        continuation?.finish()
        continuation = nil
    }
}

@Suite("Robustness on a noisy line")
struct NoiseTests {
    @Test("Stray characters between sweeps do not derail the next one")
    func toleratesNoise() async throws {
        let channel = NoisySimulatedChannel()
        let session = AnalyzerSession(channel: channel)
        await session.start()

        // Noise arrives while nobody is listening, exactly as it does when a calibration
        // standard is being swapped by hand.
        await channel.injectNoise("Z\r\u{7}\rQ9\r")

        let sweep = try await session.sweep(from: .megahertz(1), to: .megahertz(10), points: 20)
        #expect(sweep.points.count == 21)
        await session.stop()
    }
}

/// A simulated analyzer that also lets a test push garbage onto the line.
actor NoisySimulatedChannel: ByteChannel {
    private let inner = SimulatedAnalyzerChannel()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var pump: Task<Void, Never>?

    func received() async -> AsyncThrowingStream<Data, Error> {
        let upstream = await inner.received()
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.pump = Task {
                do {
                    for try await chunk in upstream { continuation.yield(chunk) }
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    func injectNoise(_ text: String) {
        continuation?.yield(Data(text.utf8))
    }

    func send(_ data: Data) async throws {
        try await inner.send(data)
    }

    func close() async {
        pump?.cancel()
        await inner.close()
        continuation?.finish()
    }
}
