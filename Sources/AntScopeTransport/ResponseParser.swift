import AntScopeCore
import Foundation

/// Turns the analyzer's byte stream into decoded responses.
///
/// Serial reads arrive in arbitrary chunks that rarely line up with line boundaries, so
/// the parser holds partial lines between calls. It performs no I/O, which is what makes
/// the protocol testable without an analyzer attached — the interesting failures all live
/// here rather than in the plumbing that feeds it.
public struct ResponseParser: Sendable {
    /// Lines are terminated by a carriage return. Line feeds are padding and are ignored,
    /// so CR, LF and CRLF framing all decode identically.
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A

    /// A ceiling on the unterminated line held in hand, so a device that never sends a
    /// terminator cannot grow the buffer without bound.
    public static let maximumLineLength = 64 * 1024

    private var buffer: [UInt8] = []

    public init() {}

    /// The bytes of a line seen so far but not yet terminated.
    public var pendingByteCount: Int { buffer.count }

    /// Decodes everything that has been completed by these bytes.
    public mutating func consume(_ bytes: some Sequence<UInt8>) -> [AnalyzerResponse] {
        var responses: [AnalyzerResponse] = []
        for byte in bytes {
            switch byte {
            case Self.lineFeed:
                continue
            case Self.carriageReturn:
                if let response = Self.decode(buffer) { responses.append(response) }
                buffer.removeAll(keepingCapacity: true)
            default:
                buffer.append(byte)
                if buffer.count >= Self.maximumLineLength {
                    if let response = Self.decode(buffer) { responses.append(response) }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        return responses
    }

    /// Decodes a trailing line that never got its terminator. Call this when the analyzer
    /// disconnects, not between reads.
    public mutating func flush() -> [AnalyzerResponse] {
        defer { buffer.removeAll(keepingCapacity: true) }
        return Self.decode(buffer).map { [$0] } ?? []
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private static func decode(_ bytes: [UInt8]) -> AnalyzerResponse? {
        guard !bytes.isEmpty else { return nil }
        let line = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return decode(line: line)
    }

    /// Classifies one complete line.
    ///
    /// Order matters: acknowledgements and errors are checked first because they are
    /// exact, then tab-delimited info lines, then measurements, and a version line is the
    /// last structured guess before giving up and passing the text through.
    public static func decode(line: String) -> AnalyzerResponse {
        if isAcknowledgement(line) { return .acknowledgement }
        if line.caseInsensitiveCompare("ERROR") == .orderedSame { return .error }

        if let tab = line.firstIndex(of: "\t") {
            let key = String(line[line.startIndex..<tab])
            if key == "MAC" || key == "SN" {
                return .info(key: key, value: String(line[line.index(after: tab)...]))
            }
        }

        if let points = measurements(in: line) { return .measurements(points) }
        if let version = AnalyzerVersion(line: line) { return .version(version) }
        return .unrecognized(line)
    }

    /// AntScope2 accepts any line *containing* `OK`, which would also swallow a model name
    /// or a diagnostic string that happens to include those letters. Requiring `OK` to
    /// stand alone keeps the tolerance for a padded reply without the false positives.
    private static func isAcknowledgement(_ line: String) -> Bool {
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.contains { $0.caseInsensitiveCompare("OK") == .orderedSame }
    }

    /// Decodes `frequency,R,X` triplets. A single line may carry more than one, and a
    /// trailing partial triplet is discarded rather than guessed at.
    ///
    /// Frequencies come off the wire in megahertz.
    private static func measurements(in line: String) -> [MeasurementPoint]? {
        guard line.contains(",") else { return nil }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3 else { return nil }

        var points: [MeasurementPoint] = []
        for start in stride(from: 0, to: fields.count - fields.count % 3, by: 3) {
            guard
                let megahertz = Double(fields[start]),
                let resistance = Double(fields[start + 1]),
                let reactance = Double(fields[start + 2])
            else { return nil }
            points.append(
                MeasurementPoint(
                    frequency: .megahertz(megahertz),
                    impedance: Impedance(resistance: resistance, reactance: reactance)
                )
            )
        }
        return points.isEmpty ? nil : points
    }
}
