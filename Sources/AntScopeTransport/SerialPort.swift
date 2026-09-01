import Foundation

/// A serial port the analyzer might be attached to.
public struct SerialPortInfo: Sendable, Hashable, Identifiable {
    /// The callout device path, e.g. `/dev/cu.usbserial-A50285BI`.
    public var path: String
    /// The part after `/dev/cu.`, which is what a person recognises in a menu.
    public var name: String

    public var id: String { path }

    /// Whether this looks like a USB-attached serial adapter rather than one of the ports
    /// macOS always publishes.
    public var isLikelyExternalAdapter: Bool {
        !Self.builtInNames.contains(name) && !name.hasPrefix("Bluetooth-")
    }

    private static let builtInNames: Set<String> = ["debug-console", "Bluetooth-Incoming-Port"]

    public init(path: String) {
        self.path = path
        self.name = path.hasPrefix(Self.calloutPrefix)
            ? String(path.dropFirst(Self.calloutPrefix.count))
            : path
    }

    static let calloutPrefix = "/dev/cu."
}

public enum SerialPort {
    /// Every callout device currently published by the system.
    ///
    /// macOS exposes each serial device twice, as `/dev/tty.*` and `/dev/cu.*`. Only the
    /// callout form is usable here: opening the `tty` form blocks until carrier is
    /// asserted, which a USB-UART bridge may never do.
    public static func available() -> [SerialPortInfo] {
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return devices
            .filter { $0.hasPrefix("cu.") }
            .map { SerialPortInfo(path: "/dev/" + $0) }
            .sorted { $0.name < $1.name }
    }

    /// The ports worth offering as an analyzer connection, external adapters first.
    public static func candidates() -> [SerialPortInfo] {
        available().sorted { lhs, rhs in
            if lhs.isLikelyExternalAdapter != rhs.isLikelyExternalAdapter {
                return lhs.isLikelyExternalAdapter
            }
            return lhs.name < rhs.name
        }
    }
}

/// The line settings the analyzer expects.
///
/// AntScope2 hard-codes 38400 for every model except the AA-230 ZOOM, and switches to
/// 115200 only to talk to a bootloader during a firmware update.
public enum AnalyzerSerialSettings {
    public static let defaultBaudRate: Int32 = 38400
    public static let fastBaudRate: Int32 = 115200
    public static let bootloaderBaudRate: Int32 = 115200

    /// The baud rate a given model listens at.
    public static func baudRate(forModel model: String) -> Int32 {
        model == "AA-230 ZOOM" ? fastBaudRate : defaultBaudRate
    }
}
