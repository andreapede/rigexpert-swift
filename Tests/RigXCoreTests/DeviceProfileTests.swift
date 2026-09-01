import Testing
@testable import RigXCore

@Suite("Device profiles")
struct DeviceProfileTests {
    @Test("The table carries every model AntScope2 knows")
    func tableSize() {
        #expect(DeviceProfile.all.count == 40)
    }

    @Test("A nine digit serial resolves to its model")
    func serialLookup() {
        #expect(DeviceProfile.serialPrefix(from: "165012345") == 1650)
        #expect(DeviceProfile.profile(forSerial: "165012345")?.name == "AA-650 ZOOM")
        #expect(DeviceProfile.profile(forSerial: "180000001")?.name == "Match")
        #expect(DeviceProfile.profile(forSerial: "423100042")?.name == "Stick 230")
    }

    @Test("Anything that is not a nine digit serial is rejected", arguments: [
        "", "1650", "16501234", "1650123456", "AA-650 ZOOM", "Match 12345",
    ])
    func rejectsNonSerials(candidate: String) {
        #expect(DeviceProfile.serialPrefix(from: candidate) == nil)
    }

    @Test("A shared serial prefix resolves to the first table entry")
    func duplicatePrefix() {
        // 4115 is claimed by both "AA-1500 ZOOM SE" and "AA-1500 SE"; the original's
        // linear search returns the earlier one and callers depend on that.
        let matches = DeviceProfile.all.filter { $0.serialPrefix == 4115 }
        #expect(matches.count == 2)
        #expect(DeviceProfile.profile(forSerial: "411500001")?.name == "AA-1500 ZOOM SE")
    }

    @Test("Frequency limits are carried in hertz")
    func frequencyRanges() {
        let aa3000 = DeviceProfile.profile(named: "AA-3000 ZOOM")
        #expect(aa3000?.frequencyRange.lowerBound == .kilohertz(100))
        #expect(aa3000?.frequencyRange.upperBound == .gigahertz(3))

        let aa35 = DeviceProfile.profile(named: "AA-35 ZOOM")
        #expect(aa35?.frequencyRange.upperBound == .megahertz(35))
    }

    @Test("Only models with a screen advertise screenshot support")
    func screenshotSupport() {
        #expect(DeviceProfile.profile(named: "AA-650 ZOOM")?.supportsScreenshot == true)
        #expect(DeviceProfile.profile(named: "AA-650 ZOOM")?.screenSize?.width == 320)
        #expect(DeviceProfile.profile(named: "AA-200")?.supportsScreenshot == false)
        #expect(DeviceProfile.profile(named: "NanoVNA")?.supportsScreenshot == false)
    }

    @Test("Models are reachable by alias and by reported name with trailing text")
    func nameLookup() {
        #expect(DeviceProfile.profile(named: "AA-2000")?.name == "AA-2000 ZOOM")
        #expect(DeviceProfile.profile(named: "AA-1500SE")?.name == "AA-1500 ZOOM SE")
        #expect(DeviceProfile.profile(named: "Stick Pro v2")?.name == "Stick Pro")
        #expect(DeviceProfile.profile(named: "Nonexistent") == nil)
    }
}
