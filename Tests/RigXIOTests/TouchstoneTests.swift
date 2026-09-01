import RigXCore
import Foundation
import Testing
@testable import RigXIO

@Suite("Touchstone files")
struct TouchstoneTests {
    static func fixture(_ name: String) throws -> URL {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "s1p"),
            "missing fixture \(name).s1p"
        )
        return url
    }

    @Test("Reads the calibration standards shipped with AntScope2", arguments: [
        "cal_open", "cal_short", "cal_load",
    ])
    func readsShippedStandards(name: String) throws {
        let file = try TouchstoneFile.read(contentsOf: Self.fixture(name))
        #expect(file.points.count == 501)
        #expect(file.referenceImpedance == 50)
        #expect(file.points.first?.frequency == .megahertz(0.0001))
        #expect(file.points.last?.frequency == .megahertz(0.2296))
    }

    @Test("Recovers the exact reflection coefficients written in the file")
    func recoversGamma() throws {
        let file = try TouchstoneFile.read(contentsOf: Self.fixture("cal_open"))
        let first = try #require(file.points.first).reflection(referenceImpedance: file.referenceImpedance)
        #expect(abs(first.real - 0.989605) < 1e-6)
        #expect(abs(first.imaginary - (-0.0971299)) < 1e-6)
    }

    @Test("A file survives a write and read round trip")
    func roundTrip() throws {
        let original = TouchstoneFile(
            points: [
                MeasurementPoint(frequency: .megahertz(14.2), impedance: Impedance(resistance: 50, reactance: 0)),
                MeasurementPoint(frequency: .megahertz(21.05), impedance: Impedance(resistance: 73, reactance: 42.5)),
                MeasurementPoint(frequency: .megahertz(28.4), impedance: Impedance(resistance: 12, reactance: -30)),
            ]
        )
        let reparsed = try TouchstoneFile.parse(original.serialized())

        #expect(reparsed.points.count == original.points.count)
        #expect(reparsed.referenceImpedance == original.referenceImpedance)
        for (expected, actual) in zip(original.points, reparsed.points) {
            #expect(abs(actual.frequency.hertz - expected.frequency.hertz) < 1)
            #expect(abs(actual.impedance.resistance - expected.impedance.resistance) < 1e-3)
            #expect(abs(actual.impedance.reactance - expected.impedance.reactance) < 1e-3)
        }
    }

    @Test("The header we emit is the one AntScope2 emits")
    func headerFormat() {
        let file = TouchstoneFile(points: [
            MeasurementPoint(frequency: .megahertz(1), impedance: Impedance(resistance: 50, reactance: 0))
        ])
        let lines = file.serialized().split(separator: "\n")
        #expect(lines[1] == "# MHz S RI R 50")
    }

    @Test("Lowercase kHz parses, unlike the original")
    func lowercaseUnitKeyword() throws {
        // calibration.h compares unit keywords with strcmp against "KHz", so a file
        // written with the spec's own "kHz" silently falls back to gigahertz.
        let file = try TouchstoneFile.parse("# kHz S RI R 50\n1000 0 0\n")
        #expect(file.points.first?.frequency == .megahertz(1))
    }

    @Test("Trailing comments on data lines are stripped, not fatal")
    func inlineComments() throws {
        let file = try TouchstoneFile.parse("# MHz S RI R 50\n14.2 0.1 0.2 ! marker\n21.0 0 0\n")
        #expect(file.points.count == 2)
    }

    @Test("Magnitude-angle files decode to the same impedance as real-imaginary ones")
    func magnitudeAngleFormat() throws {
        let realImaginary = try TouchstoneFile.parse("# MHz S RI R 50\n14.2 0 0.5\n")
        let magnitudeAngle = try TouchstoneFile.parse("# MHz S MA R 50\n14.2 0.5 90\n")
        let a = try #require(realImaginary.points.first).impedance
        let b = try #require(magnitudeAngle.points.first).impedance
        #expect(abs(a.resistance - b.resistance) < 1e-9)
        #expect(abs(a.reactance - b.reactance) < 1e-9)
    }

    @Test("An unusable reference impedance is rejected")
    func rejectsBadReferenceImpedance() {
        #expect(throws: TouchstoneError.invalidReferenceImpedance(0)) {
            try TouchstoneFile.parse("# MHz S RI R 0\n1 0 0\n")
        }
    }

    @Test("A file with no data points is rejected")
    func rejectsEmptyFile() {
        #expect(throws: TouchstoneError.noDataPoints) {
            try TouchstoneFile.parse("! only a comment\n# MHz S RI R 50\n")
        }
    }
}
