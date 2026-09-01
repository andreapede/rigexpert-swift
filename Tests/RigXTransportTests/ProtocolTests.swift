import RigXCore
import Testing
@testable import RigXTransport

@Suite("Commands")
struct AnalyzerCommandTests {
    @Test("Sweep setup is a centre, a width and a point count")
    func sweepCommands() {
        let commands = AnalyzerCommand.sweep(
            from: .megahertz(1), to: .megahertz(30), points: 500
        )
        #expect(commands.map(\.wireFormat) == ["FQ15500000\r", "SW29000000\r", "FRX500\r"])
    }

    @Test("A single frequency is a sweep of zero width")
    func singlePoint() {
        let commands = AnalyzerCommand.singlePoint(at: .megahertz(14.2))
        #expect(commands.map(\.wireFormat) == ["FQ14200000\r", "SW0\r", "FRX1\r"])
    }

    @Test("The AA-30 ZERO's full range round-trips through centre and width")
    func fullRangeSweep() {
        let profile = DeviceProfile.profile(named: "AA-30 ZERO")!
        let commands = AnalyzerCommand.sweep(
            from: profile.frequencyRange.lowerBound,
            to: profile.frequencyRange.upperBound,
            points: 500
        )
        // 60 kHz to 30 MHz: centre 15.03 MHz, width 29.94 MHz.
        #expect(commands[0].wireFormat == "FQ15030000\r")
        #expect(commands[1].wireFormat == "SW29940000\r")
    }

    @Test("Measurement modes select the right verb")
    func measurementModes() {
        #expect(AnalyzerCommand.measure(points: 100, mode: .reflection).wireFormat == "FRX100\r")
        #expect(AnalyzerCommand.measure(points: 100, mode: .extendedReflection).wireFormat == "EFRX100\r")
        #expect(AnalyzerCommand.measure(points: 100, mode: .transmission).wireFormat == "FDB100\r")
    }

    @Test("Housekeeping commands match the bytes AntScope2 sends")
    func housekeeping() {
        #expect(AnalyzerCommand.version.wireFormat == "\r\nVER\r")
        #expect(AnalyzerCommand.ping.wireFormat == "ping\r")
        #expect(AnalyzerCommand.stop.wireFormat == "off\r")
        #expect(AnalyzerCommand.storedDataIndex.wireFormat == "FLASHH\r")
        #expect(AnalyzerCommand.storedSweep(slot: 3).wireFormat == "FLASHFRX3\r")
    }
}

@Suite("Version line")
struct AnalyzerVersionTests {
    @Test("An AA-30 ZERO identifies itself")
    func aa30Zero() throws {
        let version = try #require(AnalyzerVersion(line: "AA-30 ZERO 100 REV 1"))
        #expect(version.model == "AA-30 ZERO")
        #expect(version.firmware == "100")
        #expect(version.revision == "1")
        #expect(version.profile?.frequencyRange.upperBound == .megahertz(30))
    }

    @Test("A missing revision is absent, not empty")
    func withoutRevision() throws {
        let version = try #require(AnalyzerVersion(line: "AA-30 ZERO 100"))
        #expect(version.firmware == "100")
        #expect(version.revision == nil)
    }

    @Test("The longest matching model name wins")
    func longestNameWins() throws {
        // "AA-30" is a prefix of "AA-30 ZERO", and "AA-3000 ZOOM" of nothing; matching
        // shortest-first would misidentify the ZERO as a plain AA-30.
        #expect(try #require(AnalyzerVersion(line: "AA-30 ZERO 100")).model == "AA-30 ZERO")
        #expect(try #require(AnalyzerVersion(line: "AA-30 105")).model == "AA-30")
        #expect(try #require(AnalyzerVersion(line: "AA-3000 ZOOM 210 REV 2")).model == "AA-3000 ZOOM")
    }

    @Test("A reply whose first bytes were mangled is still identified")
    func manglesHead() throws {
        // Captured from a real AA-30.ZERO behind a bit-banged link: the analyzer starts
        // answering while the bridge is still transmitting, and "AA-" is lost.
        let version = try #require(AnalyzerVersion(line: "\u{05}\u{FFFD}30.ZERO 200"))
        #expect(version.model == "AA-30.ZERO")
        #expect(version.firmware == "200")
        #expect(version.profile?.frequencyRange.upperBound == .megahertz(170))
    }

    @Test("Noise is not a version line", arguments: ["", "OK", "garbage", "AA-30 ZERO"])
    func rejectsNonVersions(line: String) {
        #expect(AnalyzerVersion(line: line) == nil)
    }
}

@Suite("Response parser")
struct ResponseParserTests {
    @Test("A complete exchange decodes in order")
    func fullExchange() {
        var parser = ResponseParser()
        let responses = parser.consume(Array("OK\rOK\r14.200000,50.1,-0.3\r".utf8))
        #expect(responses.count == 3)
        #expect(responses[0] == .acknowledgement)
        #expect(responses[1] == .acknowledgement)
        guard case .measurements(let points) = responses[2] else {
            Issue.record("expected measurements, got \(responses[2])")
            return
        }
        #expect(points.count == 1)
        #expect(points[0].frequency == .megahertz(14.2))
        #expect(points[0].impedance.resistance == 50.1)
        #expect(points[0].impedance.reactance == -0.3)
    }

    @Test("A line split across reads is held until it completes")
    func partialLines() {
        var parser = ResponseParser()
        #expect(parser.consume(Array("14.2,50".utf8)).isEmpty)
        #expect(parser.pendingByteCount == 7)
        #expect(parser.consume(Array(".1,-0".utf8)).isEmpty)

        let responses = parser.consume(Array(".3\r".utf8))
        #expect(responses.count == 1)
        #expect(parser.pendingByteCount == 0)
        guard case .measurements(let points) = responses[0] else {
            Issue.record("expected measurements")
            return
        }
        #expect(points[0].impedance.reactance == -0.3)
    }

    @Test("Byte-at-a-time delivery decodes the same as one big chunk")
    func byteAtATime() {
        let stream = "AA-30 ZERO 100 REV 1\rOK\r1.0,50,0\r"
        var whole = ResponseParser()
        let atOnce = whole.consume(Array(stream.utf8))

        var trickle = ResponseParser()
        var oneByOne: [AnalyzerResponse] = []
        for byte in Array(stream.utf8) {
            oneByOne += trickle.consume([byte])
        }
        #expect(atOnce == oneByOne)
        #expect(atOnce.count == 3)
    }

    @Test("CR, LF and CRLF framing all decode identically", arguments: ["\r", "\r\n", "\n\r"])
    func lineTerminators(terminator: String) {
        var parser = ResponseParser()
        let responses = parser.consume(Array("OK\(terminator)ERROR\(terminator)".utf8))
        #expect(responses == [.acknowledgement, .error])
    }

    @Test("One line can carry several triplets")
    func multiplePointsPerLine() {
        var parser = ResponseParser()
        let responses = parser.consume(Array("1.0,50,0,2.0,51,1,3.0,52,2\r".utf8))
        guard case .measurements(let points) = responses.first else {
            Issue.record("expected measurements")
            return
        }
        #expect(points.count == 3)
        #expect(points[2].frequency == .megahertz(3))
        #expect(points[2].impedance.reactance == 2)
    }

    @Test("A trailing partial triplet is dropped, not guessed")
    func trailingPartialTriplet() {
        var parser = ResponseParser()
        let responses = parser.consume(Array("1.0,50,0,2.0,51\r".utf8))
        guard case .measurements(let points) = responses.first else {
            Issue.record("expected measurements")
            return
        }
        #expect(points.count == 1)
    }

    @Test("Empty lines produce nothing")
    func emptyLines() {
        var parser = ResponseParser()
        #expect(parser.consume(Array("\r\r\n\r   \r".utf8)).isEmpty)
    }

    @Test("Identity lines are decoded as info")
    func infoLines() {
        var parser = ResponseParser()
        let responses = parser.consume(Array("SN\t123456789\rMAC\tAA:BB:CC:DD:EE:FF\r".utf8))
        #expect(responses[0] == .info(key: "SN", value: "123456789"))
        #expect(responses[1] == .info(key: "MAC", value: "AA:BB:CC:DD:EE:FF"))
    }

    @Test("An unfamiliar line is passed through rather than dropped")
    func unrecognizedLines() {
        var parser = ResponseParser()
        #expect(parser.consume(Array("something unexpected\r".utf8)) == [.unrecognized("something unexpected")])
    }

    @Test("A model name containing OK is not mistaken for an acknowledgement")
    func acknowledgementIsAWholeWord() {
        // AntScope2 accepts any line containing "OK", so a line like this one would be
        // swallowed as a handshake and the real response lost.
        var parser = ResponseParser()
        #expect(parser.consume(Array("BOOKMARK 1\r".utf8)) == [.unrecognized("BOOKMARK 1")])
        #expect(parser.consume(Array("  OK  \r".utf8)) == [.acknowledgement])
    }

    @Test("An unterminated line is only decoded on an explicit flush")
    func flush() {
        var parser = ResponseParser()
        #expect(parser.consume(Array("OK".utf8)).isEmpty)
        #expect(parser.flush() == [.acknowledgement])
        #expect(parser.flush().isEmpty)
    }

    @Test("A device that never sends a terminator cannot grow the buffer without bound")
    func runawayLineIsCapped() {
        var parser = ResponseParser()
        let flood = Array(String(repeating: "x", count: ResponseParser.maximumLineLength + 10).utf8)
        let responses = parser.consume(flood)
        #expect(responses.count == 1)
        #expect(parser.pendingByteCount == 10)
    }

    @Test("A full AA-30 ZERO sweep decodes to the expected number of points")
    func syntheticSweep() {
        // What the analyzer answers to FQ/SW/FRX: two acknowledgements then one line per point.
        var transcript = "OK\rOK\r"
        for index in 0..<500 {
            let megahertz = 0.06 + Double(index) * (29.94 / 500)
            transcript += String(format: "%.6f,%.2f,%.2f\r", megahertz, 50.0, 0.0)
        }

        var parser = ResponseParser()
        let responses = parser.consume(Array(transcript.utf8))
        let points = responses.compactMap { response -> [MeasurementPoint]? in
            guard case .measurements(let points) = response else { return nil }
            return points
        }.flatMap(\.self)

        #expect(responses.prefix(2) == [.acknowledgement, .acknowledgement])
        #expect(points.count == 500)
        #expect(points.first!.frequency.megahertz == 0.06)
    }
}

@Suite("Serial ports")
struct SerialPortTests {
    @Test("Enumeration finds the callout devices this Mac publishes")
    func enumeration() {
        let ports = SerialPort.available()
        #expect(ports.allSatisfy { $0.path.hasPrefix("/dev/cu.") })
        #expect(ports.contains { $0.name == "Bluetooth-Incoming-Port" },
                "macOS always publishes this one")
    }

    @Test("Built-in ports are not offered as analyzer candidates")
    func candidateOrdering() {
        #expect(SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port").isLikelyExternalAdapter == false)
        #expect(SerialPortInfo(path: "/dev/cu.debug-console").isLikelyExternalAdapter == false)
        #expect(SerialPortInfo(path: "/dev/cu.usbserial-A50285BI").isLikelyExternalAdapter)
        #expect(SerialPortInfo(path: "/dev/cu.SLAB_USBtoUART").isLikelyExternalAdapter)
    }

    @Test("The AA-30 ZERO speaks at 38400")
    func baudRate() {
        #expect(AnalyzerSerialSettings.baudRate(forModel: "AA-30 ZERO") == 38400)
        #expect(AnalyzerSerialSettings.baudRate(forModel: "AA-230 ZOOM") == 115200)
    }
}
