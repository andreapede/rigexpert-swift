import RigXCore
import RigXIO
import RigXTransport
import Foundation

/// A minimal command line client, so an analyzer can be exercised the moment it is
/// plugged in — before any UI exists.
@main
struct Probe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch arguments.first {
            case "ports": listPorts()
            case "identify": try await identify(arguments)
            case "sweep": try await sweep(arguments)
            case "cable": try cable(arguments)
            case "tdr": try tdr(arguments)
            case "calibrate": try await calibrate(arguments)
            case "monitor": try await monitor(arguments)
            case "demo": try await demo()
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func usage() {
        print("""
        rigx-probe — talk to a RigExpert analyzer

          ports                                    list serial ports
          identify <port> [--baud N] [--settle S]  ask the analyzer what it is
          sweep <port> <startMHz> <endMHz> <points> [--baud N] [--cal cal.json] [--out file.s1p]
          calibrate <port> [startMHz endMHz points] [--baud N] [--out cal.json]
          cable <file.s1p> [--length METRES]       measure a cable from a saved sweep
          tdr <file.s1p> [--vf F] [--window W]     time domain view of a saved sweep
          monitor <port> [seconds] [--baud N] [--settle S] [--send TEXT]  dump raw bytes
          demo                                     run a sweep against the simulator

        The analyzer speaks at 38400, which is the default. Behind the Arduino bridge
        the Mac side runs at 115200 instead: add --baud 115200.
        """)
    }

    static func listPorts() {
        let ports = SerialPort.candidates()
        guard !ports.isEmpty else {
            print("no serial ports found")
            return
        }
        for port in ports {
            let marker = port.isLikelyExternalAdapter ? "*" : " "
            print("\(marker) \(port.path)")
        }
        if ports.contains(where: \.isLikelyExternalAdapter) {
            print("\n* = external adapter, most likely your analyzer")
        }
    }

    /// The Mac-side baud rate. With a direct USB-UART adapter this is the analyzer's own
    /// 38400; behind an Arduino bridge it is whatever the bridge's USB side runs at.
    static func baudRate(from arguments: [String]) -> Int32 {
        if let flag = arguments.firstIndex(of: "--baud"), arguments.count > flag + 1,
           let value = Int32(arguments[flag + 1]) {
            return value
        }
        return AnalyzerSerialSettings.defaultBaudRate
    }

    /// Seconds to wait after opening before speaking.
    ///
    /// Most Arduino boards reset when the host asserts DTR on open, and anything sent
    /// during the bootloader window is swallowed. Two seconds covers it.
    static func settleDelay(from arguments: [String]) -> Double {
        if let flag = arguments.firstIndex(of: "--settle"), arguments.count > flag + 1,
           let value = Double(arguments[flag + 1]) {
            return value
        }
        return 2.0
    }

    static func session(for arguments: [String]) async throws -> AnalyzerSession {
        guard arguments.count > 1 else { throw ProbeError.missingPort }
        let channel = SerialChannel(path: arguments[1], baudRate: baudRate(from: arguments))
        try await channel.open()
        try await Task.sleep(for: .seconds(settleDelay(from: arguments)))
        let session = AnalyzerSession(channel: channel)
        await session.start()
        return session
    }

    static func identify(_ arguments: [String]) async throws {
        let session = try await session(for: arguments)
        defer { Task { await session.stop() } }

        let version = try await session.identify()
        print("model:    \(version.model)")
        print("firmware: \(version.firmware)")
        if let revision = version.revision { print("revision: \(revision)") }
        if let profile = version.profile {
            print("range:    \(profile.frequencyRange.lowerBound) – \(profile.frequencyRange.upperBound)")
        } else {
            print("range:    unknown — model not in the capability table")
        }
    }

    static func sweep(_ arguments: [String]) async throws {
        guard arguments.count >= 5,
              let start = Double(arguments[2]),
              let end = Double(arguments[3]),
              let points = Int(arguments[4])
        else { throw ProbeError.badArguments }

        let session = try await session(for: arguments)
        defer { Task { await session.stop() } }

        let version = try await session.identify()
        print("connected to \(version.model) \(version.firmware)\n")

        var sweep = try await session.sweep(
            from: .megahertz(start), to: .megahertz(end), points: points
        )
        if let calibration = try loadCalibration(arguments) {
            sweep = calibration.corrected(sweep)
            print("calibrazione applicata (\(calibration.points.count) punti)\n")
        }
        report(sweep)
        if let cable = CableAnalyzer.measure(sweep), cable.isCredible {
            report(cable: cable, knownLength: nil)
        }
        try writeIfRequested(sweep, arguments: arguments)
    }

    /// Prints whatever comes off the port, byte for byte. The diagnostic of last resort
    /// when a link will not come up: it shows whether anything is arriving at all,
    /// before any protocol interpretation can hide it.
    static func monitor(_ arguments: [String]) async throws {
        guard arguments.count > 1 else { throw ProbeError.missingPort }
        let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 5 : 5
        let baud = baudRate(from: arguments)
        print("--- \(arguments[1]) at \(baud) baud ---")
        let channel = SerialChannel(path: arguments[1], baudRate: baud)
        try await channel.open()
        let stream = await channel.received()

        let listener = Task {
            var total = 0
            for try await chunk in stream {
                total += chunk.count
                FileHandle.standardOutput.write(Data(escape(chunk).utf8))
            }
            return total
        }

        if let flag = arguments.firstIndex(of: "--send"), arguments.count > flag + 1 {
            // Same reset window as everywhere else: a board that restarts when the port
            // opens will not hear anything sent during its bootloader.
            try await Task.sleep(for: .seconds(settleDelay(from: arguments)))
            let text = arguments[flag + 1].replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\n", with: "\n")
            print("\n--- sending: \(escape(Data(text.utf8))) ---")
            try await channel.send(Data(text.utf8))
        }

        try await Task.sleep(for: .seconds(seconds))
        listener.cancel()
        await channel.close()
        print("\n--- \(seconds)s elapsed ---")
    }

    /// Renders bytes so that control characters are visible rather than acted on.
    static func escape(_ data: Data) -> String {
        var out = ""
        for byte in data {
            switch byte {
            case 0x0D: out += "<CR>"
            case 0x0A: out += "<LF>\n"
            case 0x20...0x7E: out.append(Character(UnicodeScalar(byte)))
            default: out += String(format: "<%02X>", byte)
            }
        }
        return out
    }

    /// Walks through an open/short/load calibration.
    ///
    /// The three sweeps must share a frequency grid and a physical setup: same adapter,
    /// same cable, nothing moved but the standard itself. Calibration nulls out everything
    /// before the plane where the standards are attached, so changing that plane
    /// afterwards invalidates it.
    static func calibrate(_ arguments: [String]) async throws {
        let start = arguments.count > 2 ? Double(arguments[2]) ?? 0.1 : 0.1
        let end = arguments.count > 3 ? Double(arguments[3]) ?? 170 : 170
        let points = arguments.count > 4 ? Int(arguments[4]) ?? 501 : 501

        let session = try await session(for: arguments)
        defer { Task { await session.stop() } }

        let version = try await session.identify()
        print("\nCalibrazione di \(version.model) \(version.firmware)")
        print("\(start)–\(end) MHz, \(points) punti, circa \(Int(Double(points) * 0.125)) s per standard\n")

        var sweeps: [String: Sweep] = [:]
        for standard in ["OPEN (connettore libero)", "SHORT (centrale in corto con la calza)", "LOAD (carico da 50 ohm)"] {
            print("Collega  \(standard)  e premi Invio…", terminator: " ")
            _ = readLine()
            let sweep = try await session.sweep(
                from: .megahertz(start), to: .megahertz(end), points: points, name: standard
            ) { _, done, total in
                if done % 25 == 0 || done == total {
                    FileHandle.standardOutput.write(Data("  \(done)/\(total)\r".utf8))
                }
            }
            print("  \(sweep.points.count)/\(points) punti")
            sweeps[String(standard.prefix(4)).trimmingCharacters(in: .whitespaces)] = sweep
            report(quality: sweep, standard: standard)
        }

        guard let open = sweeps["OPEN"], let short = sweeps["SHOR"], let load = sweeps["LOAD"],
              let calibration = Calibration(open: open, short: short, load: load)
        else { throw ProbeError.calibrationFailed }

        let url = URL(fileURLWithPath: outputPath(arguments) ?? "calibration.json")
        try JSONEncoder().encode(calibration).write(to: url)
        print("\nCalibrazione salvata in \(url.path)")
        print("Usala con:  sweep <porta> <da> <a> <punti> --cal \(url.lastPathComponent)")
    }

    /// Warns when a standard does not look like itself — the commonest calibration
    /// mistake is measuring the same thing twice or swapping two of them.
    static func report(quality sweep: Sweep, standard: String) {
        let magnitudes = sweep.points.map { $0.reflection().magnitude }
        guard let lowest = magnitudes.indices.min(by: { magnitudes[$0] < magnitudes[$1] }),
              let highest = magnitudes.indices.max(by: { magnitudes[$0] < magnitudes[$1] })
        else { return }
        let low = magnitudes[lowest]
        let high = magnitudes[highest]
        let phases = sweep.points.map { abs($0.reflection().phaseDegrees) }
        let averagePhase = phases.reduce(0, +) / Double(phases.count)

        // Where the extremes fall matters more than their value: a standard that behaves
        // across the working range and falls apart at the top says the calibration span is
        // too wide, not that the standard is wrong.
        print(String(
            format: "  |Γ| da %.3f (a %.2f MHz) a %.3f (a %.2f MHz), fase media %.0f°",
            low, sweep.points[lowest].frequency.megahertz,
            high, sweep.points[highest].frequency.megahertz,
            averagePhase
        ))
        if standard.hasPrefix("OPEN"), low < 0.8 {
            print("  ⚠︎ un open dovrebbe riflettere quasi tutto: |Γ| vicino a 1")
        }
        if standard.hasPrefix("SHORT"), low < 0.8 {
            print("  ⚠︎ uno short dovrebbe riflettere quasi tutto: |Γ| vicino a 1")
        }
        if standard.hasPrefix("LOAD"), high > 0.25 {
            print("  ⚠︎ un carico da 50 ohm dovrebbe riflettere poco: |Γ| vicino a 0")
        }
    }

    static func outputPath(_ arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--out"), arguments.count > flag + 1 else { return nil }
        return arguments[flag + 1]
    }

    static func loadCalibration(_ arguments: [String]) throws -> Calibration? {
        guard let flag = arguments.firstIndex(of: "--cal"), arguments.count > flag + 1 else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[flag + 1]))
        return try JSONDecoder().decode(Calibration.self, from: data)
    }

    /// Measures the cable a saved sweep was taken through.
    static func cable(_ arguments: [String]) throws {
        guard arguments.count > 1 else { throw ProbeError.badArguments }
        let file = try TouchstoneFile.read(contentsOf: URL(fileURLWithPath: arguments[1]))
        let sweep = Sweep(
            name: arguments[1],
            referenceImpedance: file.referenceImpedance,
            points: file.points
        )
        var length: Double?
        if let flag = arguments.firstIndex(of: "--length"), arguments.count > flag + 1 {
            length = Double(arguments[flag + 1])
        }
        if let feedline = sweep.feedlineEstimate, feedline.isCredible {
            report(feedline: feedline, knownLength: length)
        }
        guard let measurement = CableAnalyzer.measure(sweep) else {
            print("sweep troppo corto per una misura di cavo")
            return
        }
        report(cable: measurement, knownLength: length)
    }

    /// Time domain view of a saved sweep.
    static func tdr(_ arguments: [String]) throws {
        guard arguments.count > 1 else { throw ProbeError.badArguments }
        let file = try TouchstoneFile.read(contentsOf: URL(fileURLWithPath: arguments[1]))
        let sweep = Sweep(name: arguments[1], referenceImpedance: file.referenceImpedance, points: file.points)

        var velocityFactor = 0.66
        if let flag = arguments.firstIndex(of: "--vf"), arguments.count > flag + 1,
           let value = Double(arguments[flag + 1]) { velocityFactor = value }
        var window = TDRWindow.hann
        if let flag = arguments.firstIndex(of: "--window"), arguments.count > flag + 1,
           let value = TDRWindow(rawValue: arguments[flag + 1]) { window = value }

        guard let response = TimeDomain.transform(sweep, velocityFactor: velocityFactor, window: window) else {
            print("sweep non adatto: serve una griglia di frequenze uniforme e almeno 8 punti")
            return
        }

        print(String(format: "\n  finestra %@ · VF %.3f", response.window.name, velocityFactor))
        print(String(format: "  risoluzione %.2f m · portata non ambigua %.0f m",
                     response.resolution, response.unambiguousRange))
        if let peak = response.dominantDiscontinuity {
            print(String(format: "  discontinuità principale a %.2f m  (± %.2f)  ampiezza %.3f",
                         peak.distance, response.resolution / 2, peak.magnitude))
        }

        // A coarse profile, one line per resolution cell, out to a few cells past the
        // strongest feature: printing every bin would imply detail the bandwidth cannot
        // support.
        let cell = max(1, Int(response.resolution / max(response.distanceStep, 1e-9) / 4))
        let limit = min(response.distances.count, cell * 40)
        print("\n  distanza    |Γ|     Z")
        print("  ---------------------------")
        for index in stride(from: 0, to: limit, by: cell) {
            let bar = String(repeating: "▇", count: min(28, Int(abs(response.impulse[index]) * 120)))
            print(String(format: "  %6.2f m  %6.3f %6.1f Ω  %@",
                         response.distances[index], abs(response.impulse[index]),
                         response.impedance[index], bar))
        }
    }

    static func report(feedline: FeedlineEstimate, knownLength: Double?) {
        print("\n  \(feedline.crossingCount) attraversamenti X=0 a passo regolare:")
        print("  non sono risonanze d'antenna, sono la linea di discesa")
        print(String(format: "    passo               %.2f MHz", feedline.crossingSpacing.megahertz))
        print(String(format: "    lunghezza elettrica %.3f m", feedline.electricalLength))
        print(String(format: "    irregolarità        %.1f%%", feedline.irregularity * 100))
        if let knownLength {
            print(String(format: "    fattore di velocità %.4f  (con L = %.2f m)",
                         feedline.velocityFactor(physicalLength: knownLength), knownLength))
        } else {
            for (name, factor) in [("PE pieno", 0.66), ("PE espanso", 0.80)] {
                let padded = name.padding(toLength: 12, withPad: " ", startingAt: 0)
                print("    \(padded) VF \(String(format: "%.2f", factor)) -> \(String(format: "%.3f", feedline.physicalLength(velocityFactor: factor))) m")
            }
        }
    }

    static func report(cable measurement: CableMeasurement, knownLength: Double?) {
        print(String(format: "\n  ritardo andata-ritorno   %.3f ns", measurement.roundTripDelay * 1e9))
        print(String(format: "  periodo interferenza     %.2f MHz", 1 / measurement.roundTripDelay / 1e6))
        print(String(format: "  lunghezza elettrica      %.3f m", measurement.electricalLength))
        print(String(format: "  riflessione al piano     %.4f", measurement.nearReflection.magnitude))
        print(String(format: "  riflessione in fondo     %.4f", measurement.farReflection.magnitude))
        print(String(format: "  residuo rms              %.5f%@",
                     measurement.residual, measurement.isCredible ? "" : "   ⚠︎ fit poco attendibile"))

        if let knownLength {
            print(String(format: "\n  fattore di velocità      %.4f   (con L = %.3f m)",
                         measurement.velocityFactor(physicalLength: knownLength), knownLength))
        } else {
            print("\n  lunghezza secondo il fattore di velocità:")
            for (name, factor) in [("PE pieno", 0.66), ("PTFE", 0.695), ("PE espanso", 0.80)] {
                // Not String(format:) with %s: that expects a C string, and handing it a
                // Swift String reads the string's internals as a pointer.
                let padded = name.padding(toLength: 12, withPad: " ", startingAt: 0)
                let length = String(format: "%.3f", measurement.physicalLength(velocityFactor: factor))
                print("    \(padded) VF \(String(format: "%.3f", factor))  ->  \(length) m")
            }
        }
    }

    static func demo() async throws {
        let session = AnalyzerSession(channel: SimulatedAnalyzerChannel(
            impedance: Impedance(resistance: 68, reactance: -18)
        ))
        await session.start()
        defer { Task { await session.stop() } }

        let version = try await session.identify()
        print("simulated \(version.model) \(version.firmware)\n")
        report(try await session.sweep(from: .megahertz(1), to: .megahertz(30), points: 20))
    }

    static func report(_ sweep: Sweep) {
        print("  frequency        R        X      SWR     |Γ|")
        print("  ------------------------------------------------")
        for point in sweep.points {
            let gamma = point.reflection(referenceImpedance: sweep.referenceImpedance)
            let swr = gamma.swr.map { String(format: "%7.2f", $0) } ?? "      –"
            print(String(
                format: "  %9.4f MHz %8.2f %8.2f %@ %7.3f",
                point.frequency.megahertz, point.impedance.resistance,
                point.impedance.reactance, swr, gamma.magnitude
            ))
        }
        let quality = sweep.quality
        if !quality.isClean {
            let list = quality.saturated.prefix(5).map { String(format: "%.2f", $0.megahertz) }
                .joined(separator: ", ")
            print(String(format: "\n  ⚠︎ %d campioni persi su %d (%.1f%%)%@",
                         quality.faultCount, quality.sampleCount, quality.faultFraction * 100,
                         list.isEmpty ? "" : ": |Γ| ≥ 1 a \(list) MHz"))
        }
        if let best = sweep.bestMatch {
            let swr = best.reflection(referenceImpedance: sweep.referenceImpedance).swr ?? .infinity
            print(String(format: "\n  best match: %.4f MHz at SWR %.2f", best.frequency.megahertz, swr))
        }
    }

    static func writeIfRequested(_ sweep: Sweep, arguments: [String]) throws {
        guard let flag = arguments.firstIndex(of: "--out"), arguments.count > flag + 1 else { return }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        try TouchstoneFile(points: sweep.points, referenceImpedance: sweep.referenceImpedance)
            .write(to: url)
        print("\n  written to \(url.path)")
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case missingPort
    case badArguments
    case calibrationFailed

    var description: String {
        switch self {
        case .missingPort: "no serial port given — run `rigx-probe ports` to list them"
        case .badArguments: "usage: sweep <port> <startMHz> <endMHz> <points> [--out file.s1p]"
        case .calibrationFailed: "i tre sweep non condividono la stessa griglia di frequenze"
        }
    }
}
