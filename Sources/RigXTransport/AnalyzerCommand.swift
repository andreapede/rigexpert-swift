import RigXCore
import Foundation

/// A command in the RigExpert AA text protocol.
///
/// The whole vocabulary an analyzer understands, as far as AntScope2 uses it. Commands
/// are ASCII and terminated by a carriage return; the analyzer answers each one with
/// `OK` before it will accept the next.
public enum AnalyzerCommand: Sendable, Hashable {
    /// Asks the analyzer to identify itself. Answered with a version line rather than `OK`.
    case version
    /// Keepalive. AntScope2 sends this once a second while idle.
    case ping
    /// Sets the sweep centre frequency.
    case centerFrequency(Frequency)
    /// Sets the sweep width. Zero measures a single frequency.
    case sweepWidth(Frequency)
    /// Starts a sweep of `points` steps, streaming back `frequency,R,X` lines.
    case measure(points: Int, mode: MeasurementMode)
    /// Aborts a sweep in progress.
    case stop
    /// Dumps the measurement slots stored in the analyzer's flash.
    case storedDataIndex
    /// Dumps one stored sweep.
    case storedSweep(slot: Int)

    public enum MeasurementMode: Sendable, Hashable {
        /// Standard R/X sweep.
        case reflection
        /// Extended sweep, which adds the analyzer's own user parameters.
        case extendedReflection
        /// Transmission (S21) sweep, on models that have a second port.
        case transmission
    }

    /// The exact bytes AntScope2 puts on the wire.
    public var wireFormat: String {
        switch self {
        case .version:
            // The leading CRLF flushes any half-line the analyzer may have buffered.
            //
            // AntScope2 ends this with CRLF. We stop at the CR, because the analyzer
            // starts answering the moment it sees it and a bit-banged link is deaf while
            // it transmits: that trailing line feed is 260 microseconds of blindness
            // right where the first bytes of the reply arrive. The analyzer ignores line
            // feeds anyway — it frames on CR.
            "\r\nVER\r"
        case .ping:
            "ping\r"
        case .centerFrequency(let frequency):
            "FQ\(Int(frequency.hertz.rounded()))\r"
        case .sweepWidth(let frequency):
            "SW\(Int(frequency.hertz.rounded()))\r"
        case .measure(let points, let mode):
            switch mode {
            case .reflection: "FRX\(points)\r"
            case .extendedReflection: "EFRX\(points)\r"
            case .transmission: "FDB\(points)\r"
            }
        case .stop:
            "off\r"
        case .storedDataIndex:
            "FLASHH\r"
        case .storedSweep(let slot):
            "FLASHFRX\(slot)\r"
        }
    }

    public var data: Data { Data(wireFormat.utf8) }

    /// Whether the analyzer answers this command with a bare `OK` that the caller must
    /// wait for before sending the next one.
    public var expectsAcknowledgement: Bool {
        switch self {
        case .centerFrequency, .sweepWidth: true
        // The analyzer answers a measurement request with the measurements themselves,
        // not with an OK first — `BaseAnalyzer::startMeasure` sends FRX and stops waiting.
        case .measure, .version, .ping, .stop, .storedDataIndex, .storedSweep: false
        }
    }
}

extension AnalyzerCommand {
    /// The three-command handshake that starts a sweep.
    ///
    /// Note that `points` is a count of intervals, not of endpoints: the analyzer steps
    /// by `(end - start) / points` and the last sample lands one step short of `end`.
    ///
    /// The analyzer is told a centre and a width rather than two endpoints, so the range
    /// has to be converted. `AntScope2` does the same arithmetic inline in
    /// `BaseAnalyzer::startMeasure`, using integer division for the step.
    public static func sweep(
        from start: Frequency,
        to end: Frequency,
        points: Int,
        mode: MeasurementMode = .reflection
    ) -> [AnalyzerCommand] {
        let band = end.hertz - start.hertz
        let center = Frequency(hertz: band / 2 + start.hertz)
        return [
            .centerFrequency(center),
            .sweepWidth(Frequency(hertz: band)),
            .measure(points: points, mode: mode),
        ]
    }

    /// The commands that measure a single frequency, which the analyzer expresses as a
    /// sweep of zero width.
    public static func singlePoint(at frequency: Frequency, points: Int = 1) -> [AnalyzerCommand] {
        sweep(from: frequency, to: frequency, points: points)
    }
}
