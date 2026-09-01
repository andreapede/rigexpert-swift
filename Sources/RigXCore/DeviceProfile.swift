import Foundation

/// The static capabilities of one analyzer model.
///
/// Ported from `AnalyzerParameters::fill()` in `analyzer/analyzerparameters.h`, where the
/// same data lives as a list of constructor calls with positional arguments and bare
/// kilohertz strings.
public struct DeviceProfile: Sendable, Hashable, Identifiable, Codable {
    /// The model name as the analyzer reports it, e.g. `"AA-650 ZOOM"`.
    public var name: String
    /// A short marketing name used on some screens, when it differs from `name`.
    public var alias: String?
    public var frequencyRange: ClosedRange<Frequency>
    /// The on-device screen size in pixels, when the model has a screen that can be captured.
    public var screenSize: ScreenSize?
    /// The first four digits of the serial number that identify this model, when it has one.
    public var serialPrefix: Int?

    public var id: String { alias.map { "\(name)|\($0)" } ?? name + (serialPrefix.map { "|\($0)" } ?? "") }

    /// Whether the analyzer can stream its screen back to the host.
    public var supportsScreenshot: Bool { screenSize != nil }

    public struct ScreenSize: Sendable, Hashable, Codable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public init(
        name: String,
        alias: String? = nil,
        frequencyRange: ClosedRange<Frequency>,
        screenSize: ScreenSize? = nil,
        serialPrefix: Int? = nil
    ) {
        self.name = name
        self.alias = alias
        self.frequencyRange = frequencyRange
        self.screenSize = screenSize
        self.serialPrefix = serialPrefix
    }
}

extension DeviceProfile {
    private static func profile(
        _ name: String,
        _ minKilohertz: Double,
        _ maxKilohertz: Double,
        height: Int = 0,
        width: Int = 0,
        prefix: Int? = nil,
        alias: String? = nil
    ) -> DeviceProfile {
        DeviceProfile(
            name: name,
            alias: alias,
            frequencyRange: Frequency.kilohertz(minKilohertz)...Frequency.kilohertz(maxKilohertz),
            screenSize: (height > 0 && width > 0) ? ScreenSize(width: width, height: height) : nil,
            serialPrefix: prefix
        )
    }

    /// Every analyzer model AntScope2 knows about, in the original table's order.
    ///
    /// Order is load-bearing: several models share a serial prefix or a name, and both
    /// lookups resolve to the first match, exactly as the C++ `foreach` loops do.
    public static let all: [DeviceProfile] = [
        profile("AA-3000 ZOOM", 100, 3_000_000, height: 480, width: 746, prefix: 4003, alias: "AA-3000"),
        profile("AA-30 ZERO", 60, 30_000),
        profile("AA-30.ZERO", 60, 170_000),
        profile("AA-30", 100, 30_000, height: 64, width: 133),
        profile("AA-35 ZOOM", 60, 35_000, height: 240, width: 320, prefix: 1350),
        profile("AA-35 ZOOM", 60, 35_000, height: 240, width: 320, prefix: 1351),
        profile("AA-54", 100, 54_000, height: 64, width: 133),
        profile("AA-55 ZOOM", 60, 55_000, height: 240, width: 320, prefix: 1550),
        profile("AA-55 ZOOM", 60, 55_000, height: 240, width: 320, prefix: 1551),
        profile("AA-170", 100, 170_000, height: 64, width: 133),
        profile("AA-200", 100, 200_000),
        profile("AA-2000 ZOOM", 100, 2_000_000, height: 480, width: 746, prefix: 4002, alias: "AA-2000"),
        profile("AA-230PRO", 100, 230_000),
        profile("AA-230 ZOOM", 100, 230_000, height: 220, width: 290, prefix: 1232),
        profile("AA-230", 100, 230_000),
        profile("Stick 230", 100, 230_000, height: 200, width: 200, prefix: 4230),
        profile("Stick 230", 100, 230_000, height: 232, width: 240, prefix: 4231),
        profile("Stick Pro", 100, 600_000, height: 220, width: 220, prefix: 4600),
        profile("Stick Pro", 100, 600_000, height: 232, width: 240, prefix: 4601),
        profile("AA-500", 100, 500_000),
        profile("AA-520", 100, 520_000),
        profile("AA-600", 100, 600_000, height: 240, width: 320),
        profile("AA-650 ZOOM", 100, 650_000, height: 240, width: 320, prefix: 1650),
        profile("AA-700 ZOOM", 100, 700_000),
        profile("AA-1000", 100, 1_000_000, height: 240, width: 320),
        profile("AA-1400", 100, 1_400_000, height: 240, width: 320),
        profile("AA-1500 ZOOM", 100, 1_500_000, height: 240, width: 320, prefix: 1015),
        profile("NanoVNA", 100, 1_000_000),
        profile("Zero II", 100, 1_000_000, prefix: 4001),
        profile("Touch", 100, 1_000_000, prefix: 4005),
        profile("Touch E-Ink", 100, 1_000_000, prefix: 4004),
        profile("Stick XPro", 100, 1_000_000, height: 220, width: 220, prefix: 4999),
        profile("Stick XPro", 100, 1_000_000, height: 232, width: 240, prefix: 4998),
        profile("Stick 500", 100, 500_000, height: 200, width: 200, prefix: 4500),
        profile("Stick 500", 100, 500_000, height: 232, width: 240, prefix: 4501),
        profile("WilsonPro CAA", 100, 1_500_000, height: 240, width: 320, prefix: 1016),
        profile("AA-1500 ZOOM SE", 100, 1_500_000, height: 480, width: 746, prefix: 4115, alias: "AA-1500SE"),
        profile("AA-1500 SE", 100, 1_500_000, height: 480, width: 746, prefix: 4115),
        profile("Match", 100, 750_000, height: 480, width: 480, prefix: 1800),
        profile("MATCH U", 100, 500_000, height: 480, width: 480, prefix: 1801),
    ]

    /// The model-identifying prefix carried by a nine-digit RigExpert serial number.
    ///
    /// Returns `nil` for anything that is not nine digits, which is how the original
    /// distinguishes a real analyzer serial from a Bluetooth device name or a COM port.
    public static func serialPrefix(from serial: String) -> Int? {
        guard serial.count == 9 else { return nil }
        return Int(serial.prefix(4))
    }

    /// The model a serial number belongs to.
    public static func profile(forSerial serial: String) -> DeviceProfile? {
        guard let prefix = serialPrefix(from: serial) else { return nil }
        return all.first { $0.serialPrefix == prefix }
    }

    /// The model with the given name, matching the original's leading-substring behaviour
    /// for names the analyzer reports with trailing revision text.
    public static func profile(named name: String) -> DeviceProfile? {
        if let exact = all.first(where: { $0.name == name }) { return exact }
        if let alias = all.first(where: { $0.alias == name }) { return alias }
        return all.first { name.hasPrefix($0.name) }
    }
}
