import AntScopeCore
import Foundation

/// One decoded line from the analyzer.
public enum AnalyzerResponse: Sendable, Hashable {
    /// `OK` — the previous command was accepted.
    case acknowledgement
    /// `ERROR` — the previous command failed, usually an out-of-range sweep.
    case error
    /// The reply to `VER`.
    case version(AnalyzerVersion)
    /// A `MAC\t…` or `SN\t…` line, sent unprompted by some models on connect.
    case info(key: String, value: String)
    /// Measured points. A single line can carry several `frequency,R,X` triplets.
    case measurements([MeasurementPoint])
    /// A line that parsed as none of the above. Kept rather than dropped so that an
    /// unfamiliar model's chatter is visible when debugging instead of silently lost.
    case unrecognized(String)
}

/// What an analyzer reports about itself in response to `VER`.
public struct AnalyzerVersion: Sendable, Hashable {
    /// The model name exactly as reported, e.g. `"AA-30 ZERO"`.
    public var model: String
    /// The firmware version, e.g. `"100"`.
    public var firmware: String
    /// The hardware revision, when the analyzer states one.
    public var revision: String?
    /// The matching entry in the capability table, when the model is known.
    public var profile: DeviceProfile?

    public init(model: String, firmware: String, revision: String? = nil, profile: DeviceProfile? = nil) {
        self.model = model
        self.firmware = firmware
        self.revision = revision
        self.profile = profile
    }

    /// The shortest tail of a model name still specific enough to identify it. Six
    /// characters keeps `30.ZERO` recognisable without letting short fragments collide.
    private static let minimumRecognizableTail = 6

    /// Finds a model name in a line, tolerating a mangled head.
    ///
    /// A bit-banged link loses the first byte or two of a reply — the analyzer starts
    /// answering while the host is still transmitting, and a software UART is deaf while
    /// it sends. `AA-30.ZERO 200` arrives as `..30.ZERO 200`, which no exact match finds.
    private static func locate(_ names: [String], in line: String) -> (String, Range<String.Index>)? {
        for name in names {
            if let range = line.range(of: name) { return (name, range) }
        }
        for name in names {
            var tail = Substring(name)
            while tail.count > minimumRecognizableTail {
                tail = tail.dropFirst()
                if let range = line.range(of: tail) { return (name, range) }
            }
        }
        return nil
    }

    /// Parses a line such as `AA-30 ZERO 100 REV 1`.
    ///
    /// Recognises the model by matching against the capability table longest-name-first,
    /// because several names are prefixes of others — `AA-30` would otherwise swallow
    /// `AA-30 ZERO`, which is exactly the confusion the C++ works around with a special
    /// case for `"AA-3000 ZOOM"`.
    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Longest name first, because several are prefixes of others: matching "AA-30"
        // before "AA-30.ZERO" would report the wrong frequency range. The name is looked
        // for anywhere in the line rather than only at the start, since a bit-banged link
        // routinely mangles the first byte or two after a silence.
        let names = DeviceProfile.all.map(\.name).sorted { $0.count > $1.count }
        guard let match = Self.locate(names, in: trimmed) else { return nil }

        let known = match.0
        var remainder = String(trimmed[match.1.upperBound...]).trimmingCharacters(in: .whitespaces)

        var revision: String?
        if let range = remainder.range(of: "REV", options: [.caseInsensitive]) {
            revision = remainder[range.upperBound...].trimmingCharacters(in: .whitespaces)
            remainder = String(remainder[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        let firmware = remainder.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !firmware.isEmpty else { return nil }

        self.init(
            model: known,
            firmware: firmware,
            revision: revision?.isEmpty == true ? nil : revision,
            profile: DeviceProfile.profile(named: known)
        )
    }
}
