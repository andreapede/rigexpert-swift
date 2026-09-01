import RigXCore
import Foundation

/// A conversation with one analyzer.
///
/// Replaces `BaseAnalyzer::startMeasure`, which drives the same three-command handshake
/// through a re-entrant state machine, a 10 ms polling timer and three function-local
/// `static` variables shared across every analyzer instance. Here the handshake is
/// straight-line code and the state belongs to the actor.
public actor AnalyzerSession {
    public enum SessionError: Error, Equatable, Sendable {
        case timedOut(waitingFor: String)
        case analyzerReportedError
        case disconnected
        case unexpectedResponse(String)
        case invalidPointCount(Int)
    }

    private let channel: any ByteChannel
    private var parser = ResponseParser()
    private var buffered: [AnalyzerResponse] = []
    private var waiter: CheckedContinuation<AnalyzerResponse, any Error>?
    private var pump: Task<Void, Never>?

    /// How long to wait for a reply before giving up. The analyzer answers within
    /// milliseconds; a second is generous even across a slow Arduino bridge.
    public var replyTimeout: Duration = .seconds(2)
    /// A sweep of many points takes as long as the analyzer needs to step through them.
    public var sweepTimeout: Duration = .seconds(60)

    public private(set) var version: AnalyzerVersion?

    public func setReplyTimeout(_ timeout: Duration) { replyTimeout = timeout }
    public func setSweepTimeout(_ timeout: Duration) { sweepTimeout = timeout }

    public init(channel: any ByteChannel) {
        self.channel = channel
    }

    /// Starts consuming the channel. Call before sending anything.
    ///
    /// Subscribes before returning: an analyzer can answer within a millisecond, so a
    /// subscription set up lazily inside the pump task would miss the first reply.
    public func start() async {
        guard pump == nil else { return }
        let stream = await channel.received()
        pump = Task { [weak self] in
            do {
                for try await chunk in stream {
                    await self?.ingest(chunk)
                }
                await self?.finish(with: SessionError.disconnected)
            } catch {
                await self?.finish(with: error)
            }
        }
    }

    public func stop() async {
        pump?.cancel()
        pump = nil
        await channel.close()
        finish(with: SessionError.disconnected)
    }

    // MARK: - High level operations

    /// Asks the analyzer to identify itself, and remembers the answer.
    ///
    /// Tolerates anything that is not a version line rather than failing on it: a board
    /// that resets when the port opens spills bootloader noise, and some models greet the
    /// host with unsolicited `SN` and `MAC` lines before answering.
    @discardableResult
    public func identify(attempts: Int = 4) async throws -> AnalyzerVersion {
        // The first bytes after a silence are the ones a bit-banged link mangles, so a
        // corrupted reply is worth another ask rather than an error.
        for attempt in 0..<attempts {
            try await send(.version)
            let deadline = ContinuousClock.now.advanced(by: replyTimeout / attempts)
            while ContinuousClock.now < deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard let response = try? await nextResponse(timeout: remaining, waitingFor: "VER")
                else { break }
                if case .version(let version) = response {
                    self.version = version
                    return version
                }
            }
            _ = attempt
        }
        throw SessionError.timedOut(waitingFor: "VER")
    }

    /// Runs one sweep and returns it complete.
    ///
    /// The analyzer is told a centre and a width, acknowledges each, then streams one
    /// `megahertz,R,X` line per point.
    /// - Parameter onPoint: called as each point arrives, with the running count and the
    ///   total expected. A sweep takes seconds, so a caller that shows progress needs to
    ///   see it happen rather than waiting for the whole thing.
    public func sweep(
        from start: Frequency,
        to end: Frequency,
        points: Int,
        name: String = "Sweep",
        mode: AnalyzerCommand.MeasurementMode = .reflection,
        onPoint: (@Sendable (MeasurementPoint, Int, Int) -> Void)? = nil
    ) async throws -> Sweep {
        guard points > 0 else { throw SessionError.invalidPointCount(points) }
        discardPendingResponses()
        let commands = AnalyzerCommand.sweep(from: start, to: end, points: points, mode: mode)
        for command in commands {
            try await send(command)
            if command.expectsAcknowledgement {
                try await expectAcknowledgement(after: command)
            }
        }

        // The analyzer steps by band/points and reports both ends, so a request for N
        // yields N+1 samples covering [start, end] inclusive. Collecting only N leaves the
        // last one in the buffer, where it arrives in place of the next command's OK.
        let expected = points + 1
        var collected: [MeasurementPoint] = []
        collected.reserveCapacity(expected)

        while collected.count < expected {
            let response: AnalyzerResponse
            do {
                response = try await nextResponse(timeout: sweepTimeout, waitingFor: "sweep data")
            } catch {
                // A model that reports only N points would otherwise hang here waiting for
                // one that never comes. Having everything asked for is enough.
                if collected.count >= points { break }
                throw error
            }
            switch response {
            case .measurements(let batch):
                for point in batch where collected.count < expected {
                    collected.append(point)
                    onPoint?(point, collected.count, expected)
                }
            case .error:
                throw SessionError.analyzerReportedError
            case .acknowledgement, .info, .version, .unrecognized:
                continue  // chatter during a sweep is not fatal
            }
        }
        return Sweep(name: name, points: collected)
    }

    /// Aborts a sweep in progress.
    public func stopSweep() async throws {
        try await send(.stop)
    }

    public func send(_ command: AnalyzerCommand) async throws {
        try await channel.send(command.data)
    }

    // MARK: - Response plumbing

    /// Waits for `OK`, ignoring anything else that turns up first.
    ///
    /// Handling the hardware between sweeps — swapping a calibration standard, touching
    /// the board — puts noise on a floating line, and a software UART decodes noise into
    /// stray characters. Failing on the first thing that is not an acknowledgement means a
    /// single spurious byte can end a calibration three minutes in.
    private func expectAcknowledgement(after command: AnalyzerCommand) async throws {
        let label = command.wireFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = ContinuousClock.now.advanced(by: replyTimeout)
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let response = try await nextResponse(timeout: remaining, waitingFor: label)
            switch response {
            case .acknowledgement: return
            case .error: throw SessionError.analyzerReportedError
            default: continue
            }
        }
        throw SessionError.timedOut(waitingFor: label)
    }

    /// Throws away anything received but not yet read.
    ///
    /// Called before a sweep: whatever arrived while nobody was listening is stale by
    /// definition, and letting it through would misalign every reply that follows.
    public func discardPendingResponses() {
        buffered.removeAll()
        parser.reset()
    }

    private func ingest(_ chunk: Data) {
        for response in parser.consume(chunk) {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: response)
            } else {
                buffered.append(response)
            }
        }
    }

    private func finish(with error: any Error) {
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        }
    }

    private func nextResponse(timeout: Duration, waitingFor what: String) async throws -> AnalyzerResponse {
        if !buffered.isEmpty { return buffered.removeFirst() }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOutWaiter(what: what)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            self.waiter = continuation
        }
    }

    private func timeOutWaiter(what: String) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: SessionError.timedOut(waitingFor: what))
    }
}
