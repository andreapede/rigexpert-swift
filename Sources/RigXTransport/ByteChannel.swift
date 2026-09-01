import RigXCore
import Foundation

/// A bidirectional byte pipe to an analyzer.
///
/// Splitting this out from the session logic is what lets the protocol be exercised
/// end to end with no hardware attached: `SimulatedAnalyzerChannel` stands in for a real
/// port and behaves like an AA-30 ZERO.
public protocol ByteChannel: Sendable {
    func send(_ data: Data) async throws
    /// Bytes as they arrive, in whatever chunks the underlying device delivers.
    func received() async -> AsyncThrowingStream<Data, Error>
    func close() async
}

public enum ChannelError: Error, Equatable, Sendable {
    case cannotOpen(path: String, errno: Int32)
    case cannotConfigure(path: String, errno: Int32)
    case writeFailed(errno: Int32)
    case readFailed(errno: Int32)
    case closed
}

/// An analyzer that exists only in memory.
///
/// Answers the real command vocabulary with the real reply shapes, so a session driven
/// against it exercises the same code path as one driven against a serial port. Useful
/// for tests and for a demo mode in the app.
public actor SimulatedAnalyzerChannel: ByteChannel {
    private let model: String
    private let firmware: String
    /// The impedance the simulated antenna presents. Constant, which is enough to prove
    /// the transport; a resonance curve can be substituted later.
    private let impedance: Impedance
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var pendingOutput: [Data] = []
    private var incoming = ResponseParser()
    private var pendingCommand: [UInt8] = []

    private var centerHertz: Double = 0
    private var widthHertz: Double = 0

    /// Bytes are emitted in chunks of this size, to mimic a serial port delivering
    /// data that does not line up with line boundaries.
    private let chunkSize: Int

    public init(
        model: String = "AA-30 ZERO",
        firmware: String = "100",
        impedance: Impedance = Impedance(resistance: 50, reactance: 0),
        chunkSize: Int = 17
    ) {
        self.model = model
        self.firmware = firmware
        self.impedance = impedance
        self.chunkSize = chunkSize
    }

    public func received() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            for data in self.pendingOutput { continuation.yield(data) }
            self.pendingOutput.removeAll()
        }
    }

    public func send(_ data: Data) async throws {
        // Split on raw bytes, not Characters: Swift treats CRLF as a single grapheme
        // cluster, so comparing against "\r" or "\n" never matches a line ending that
        // arrives as CRLF — which is exactly how the VER command is framed.
        pendingCommand += data
        while let index = pendingCommand.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let command = String(decoding: pendingCommand[..<index], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            pendingCommand.removeFirst(index + 1)
            if !command.isEmpty { respond(to: command) }
        }
    }

    public func close() {
        continuation?.finish()
        continuation = nil
    }

    private func respond(to command: String) {
        if command == "VER" {
            emit("\(model) \(firmware) REV 1\r\n")
        } else if command == "ping" {
            emit("OK\r\n")
        } else if command.hasPrefix("FQ") {
            centerHertz = Double(command.dropFirst(2)) ?? 0
            emit("OK\r\n")
        } else if command.hasPrefix("SW") {
            widthHertz = Double(command.dropFirst(2)) ?? 0
            emit("OK\r\n")
        } else if command.hasPrefix("FRX") {
            emit(sweepTranscript(points: Int(command.dropFirst(3)) ?? 0))
        } else if command == "off" {
            // Silent, as the real analyzer is.
        } else {
            emit("ERROR\r\n")
        }
    }

    /// The most points any RigExpert analyzer will accept in one sweep, as `MAX_DOTS`
    /// in `analyzerparameters.h`.
    private static let maximumPoints = 2000

    private func sweepTranscript(points: Int) -> String {
        guard points > 0, points <= Self.maximumPoints else { return "ERROR\r\n" }
        // `points` counts intervals: the analyzer steps by band/points and reports both
        // ends, so N+1 samples come back. Verified against an AA-30.ZERO.
        let start = centerHertz - widthHertz / 2
        let step = widthHertz / Double(points)
        var transcript = "OK\r\n"
        for index in 0...points {
            let megahertz = (start + Double(index) * step) / 1_000_000
            transcript += String(
                format: "%.6f,%.2f,%.2f\r\n",
                megahertz, impedance.resistance, impedance.reactance
            )
        }
        return transcript
    }

    private func emit(_ text: String) {
        let bytes = Array(text.utf8)
        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            let end = min(start + chunkSize, bytes.count)
            let chunk = Data(bytes[start..<end])
            if let continuation { continuation.yield(chunk) } else { pendingOutput.append(chunk) }
        }
    }
}