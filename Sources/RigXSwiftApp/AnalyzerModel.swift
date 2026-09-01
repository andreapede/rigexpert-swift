import RigXCore
import RigXIO
import RigXTransport
import Foundation
import Observation

/// Everything the window shows, and the only place that talks to the analyzer.
@MainActor
@Observable
final class AnalyzerModel {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(AnalyzerVersion)

        var isConnected: Bool { if case .connected = self { true } else { false } }
    }

    /// Persisted, so the choice survives a relaunch; follows the system on first run.
    var language: Language = Language(
        rawValue: UserDefaults.standard.string(forKey: "language") ?? ""
    ) ?? .systemDefault {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    var strings: Strings { Strings(language: language) }

    var ports: [SerialPortInfo] = []
    var selectedPort: String?
    /// 115200 behind the Arduino bridge; 38400 straight into the analyzer.
    var baudRate: Int32 = 115200

    var connection: Connection = .disconnected
    var errorMessage: String?

    var startMegahertz: Double = 1
    var endMegahertz: Double = 30
    var points: Int = 200

    /// What the analyzer actually reported. The corrected view is derived, never stored:
    /// a calibration can be switched off, replaced or loaded after the fact, and the
    /// measurement must survive all three unchanged.
    var rawSweep: Sweep?
    var livePoints: [MeasurementPoint] = []
    var isSweeping = false
    var progress: Double = 0

    /// Recomputed when a sweep finishes or the correction is switched, never on every
    /// redraw: the delay search costs a few hundred thousand complex operations.
    var cable: CableMeasurement?
    /// The cable's real length, if the operator knows it — the input that turns the
    /// measurement into a velocity factor instead of the other way round.
    var knownCableLength: Double = 0

    /// A sweep read from a file, kept beside the live one for comparison.
    ///
    /// Loaded traces are shown exactly as saved: no calibration is applied to them. A file
    /// may already be corrected, and correcting it twice would be worse than not at all —
    /// and silently so.
    struct LoadedTrace: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var sweep: Sweep
        var isVisible = true
        var colorIndex: Int
    }

    /// Which trace the readouts and the analysis describe.
    enum Selection: Hashable {
        case live
        case loaded(UUID)
    }

    var loadedTraces: [LoadedTrace] = []
    var selection: Selection = .live

    /// Recomputed with the cable measurement, not on every redraw.
    var tdr: TimeDomainResponse?
    var tdrWindow: TDRWindow = .hann { didSet { recomputeCable() } }
    /// The cable's velocity factor. It scales the whole distance axis, so it is an input
    /// to the measurement rather than a result of it.
    var tdrVelocityFactor: Double = 0.66 { didSet { recomputeCable() } }

    var calibration: Calibration?
    var calibrationPath: String?
    var applyCalibration = true
    /// Draws the uncorrected trace behind the corrected one, so the correction is visible
    /// rather than merely asserted.
    var showRawTrace = false

    private var channel: SerialChannel?
    private var session: AnalyzerSession?

    private static let calibrationDefaultsKey = "lastCalibrationPath"

    init() {
        refreshPorts()
        if let path = UserDefaults.standard.string(forKey: Self.calibrationDefaultsKey) {
            loadCalibration(from: URL(fileURLWithPath: path))
        }
    }

    func loadCalibration(from url: URL) {
        do {
            let loaded = try JSONDecoder().decode(Calibration.self, from: Data(contentsOf: url))
            guard loaded.isUsable else {
                errorMessage = strings.calibrationTooShort
                return
            }
            calibration = loaded
            calibrationPath = url.path
            UserDefaults.standard.set(url.path, forKey: Self.calibrationDefaultsKey)
        } catch {
            errorMessage = "\(strings.calibrationUnreadable): \(error.localizedDescription)"
        }
    }

    /// Reads sweeps from Touchstone files and adds them beside the live one.
    func loadSweeps(from urls: [URL]) {
        for url in urls {
            do {
                let file = try TouchstoneFile.read(contentsOf: url)
                let sweep = Sweep(
                    name: url.deletingPathExtension().lastPathComponent,
                    referenceImpedance: file.referenceImpedance,
                    points: file.points
                )
                loadedTraces.append(
                    LoadedTrace(
                        name: sweep.name,
                        sweep: sweep,
                        colorIndex: loadedTraces.count + 1
                    )
                )
                selection = .loaded(loadedTraces[loadedTraces.count - 1].id)
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        recomputeCable()
    }

    func removeTrace(_ id: UUID) {
        loadedTraces.removeAll { $0.id == id }
        if case .loaded(let selected) = selection, selected == id { selection = .live }
        recomputeCable()
    }

    /// The trace every readout and every analysis panel describes.
    var selectedTrace: LoadedTrace? {
        guard case .loaded(let id) = selection else { return nil }
        return loadedTraces.first { $0.id == id }
    }

    func recomputeCable() {
        guard let sweep, sweep.points.count >= 8 else {
            cable = nil
            tdr = nil
            return
        }
        cable = CableAnalyzer.measure(sweep)
        tdr = TimeDomain.transform(sweep, velocityFactor: tdrVelocityFactor, window: tdrWindow)
    }

    func clearCalibration() {
        calibration = nil
        calibrationPath = nil
        UserDefaults.standard.removeObject(forKey: Self.calibrationDefaultsKey)
    }

    /// The correction actually in force: present, enabled, and covering the measurement.
    var activeCalibration: Calibration? {
        guard applyCalibration, let calibration, calibration.isUsable else { return nil }
        return calibration
    }

    /// Whether the sweep asks for frequencies the calibration never saw. Outside its range
    /// the correction is held at the nearest end, which is a guess, so say so.
    var sweepExceedsCalibration: Bool {
        guard let range = activeCalibration?.frequencyRange else { return false }
        return startMegahertz < range.lowerBound.megahertz - 1e-9
            || endMegahertz > range.upperBound.megahertz + 1e-9
    }

    func refreshPorts() {
        ports = SerialPort.candidates()
        if selectedPort == nil || !ports.contains(where: { $0.path == selectedPort }) {
            selectedPort = ports.first(where: \.isLikelyExternalAdapter)?.path ?? ports.first?.path
        }
    }

    func connect() async {
        guard let path = selectedPort else { return }
        errorMessage = nil
        connection = .connecting
        do {
            let channel = SerialChannel(path: path, baudRate: baudRate)
            try await channel.open()
            // Boards with an auto-reset line restart when the port opens; anything sent
            // during the bootloader window is lost.
            try await Task.sleep(for: .seconds(2))
            let session = AnalyzerSession(channel: channel)
            await session.start()
            let version = try await session.identify()

            self.channel = channel
            self.session = session
            connection = .connected(version)
            if let range = version.profile?.frequencyRange {
                startMegahertz = max(startMegahertz, range.lowerBound.megahertz)
                endMegahertz = min(endMegahertz, range.upperBound.megahertz)
            }
        } catch {
            connection = .disconnected
            errorMessage = describe(error)
            await teardown()
        }
    }

    func disconnect() async {
        await teardown()
        connection = .disconnected
    }

    func runSweep() async {
        guard let session, !isSweeping else { return }
        isSweeping = true
        progress = 0
        livePoints = []
        errorMessage = nil
        defer { isSweeping = false }

        do {
            let result = try await session.sweep(
                from: .megahertz(startMegahertz),
                to: .megahertz(endMegahertz),
                points: points,
                name: sweepName()
            ) { point, done, total in
                Task { @MainActor [weak self] in
                    self?.livePoints.append(point)
                    self?.progress = Double(done) / Double(total)
                }
            }
            rawSweep = result
            livePoints = result.points
            progress = 1
            recomputeCable()
        } catch {
            errorMessage = describe(error)
        }
    }

    func export(to url: URL) {
        guard let sweep else { return }
        do {
            try TouchstoneFile(points: sweep.points, referenceImpedance: sweep.referenceImpedance)
                .write(to: url)
        } catch {
            errorMessage = describe(error)
        }
    }

    /// The measurement as taken, live points while a sweep is running.
    var rawPoints: [MeasurementPoint] {
        if let selectedTrace { return selectedTrace.sweep.points }
        return isSweeping || rawSweep == nil ? livePoints : rawSweep!.points
    }

    /// Everything the comparison view should draw, live first.
    var visibleTraces: [(name: String, points: [MeasurementPoint], colorIndex: Int, isSelected: Bool)] {
        var result: [(String, [MeasurementPoint], Int, Bool)] = []
        let live = isSweeping || rawSweep == nil ? livePoints : rawSweep!.points
        if !live.isEmpty {
            result.append((strings.liveTrace, correctedIfLive(live), 0, selection == .live))
        }
        for trace in loadedTraces where trace.isVisible {
            result.append((trace.name, trace.sweep.points, trace.colorIndex, selection == .loaded(trace.id)))
        }
        return result
    }

    /// The correction belongs to the live measurement only.
    private func correctedIfLive(_ points: [MeasurementPoint]) -> [MeasurementPoint] {
        guard let calibration = activeCalibration else { return points }
        let z0 = rawSweep?.referenceImpedance ?? .standardZ0
        return points.map { point in
            MeasurementPoint(
                frequency: point.frequency,
                impedance: calibration
                    .corrected(point.reflection(referenceImpedance: z0), at: point.frequency)
                    .impedance(referenceImpedance: z0)
            )
        }
    }

    /// The finished sweep with any active correction applied — what gets exported.
    var sweep: Sweep? {
        if let selectedTrace { return selectedTrace.sweep }
        guard let rawSweep else { return nil }
        return activeCalibration?.corrected(rawSweep) ?? rawSweep
    }

    /// The points to draw.
    var displayedPoints: [MeasurementPoint] {
        if let selectedTrace { return selectedTrace.sweep.points }
        guard let calibration = activeCalibration else { return rawPoints }
        let z0 = rawSweep?.referenceImpedance ?? .standardZ0
        return rawPoints.map { point in
            let corrected = calibration.corrected(
                point.reflection(referenceImpedance: z0), at: point.frequency
            )
            return MeasurementPoint(
                frequency: point.frequency,
                impedance: corrected.impedance(referenceImpedance: z0)
            )
        }
    }

    /// What is on screen, as a sweep, so the analysis can be asked of it directly —
    /// and so it carries the reference impedance rather than assuming 50 ohm.
    var displayedSweep: Sweep {
        if let selectedTrace { return selectedTrace.sweep }
        return Sweep(
            name: rawSweep?.name ?? "",
            referenceImpedance: rawSweep?.referenceImpedance ?? .standardZ0,
            points: displayedPoints
        )
    }

    /// The lowest SWR, interpolated below the measurement grid.
    var minimumSWR: SWRMinimum? { displayedSweep.minimumSWR }

    /// Where the reactance actually crosses zero. Not the same frequency as the SWR
    /// minimum unless the resistance there happens to be the system impedance.
    var resonance: Resonance? { displayedSweep.principalResonance }

    /// Every reactance crossing, for when there are too many to be an antenna's.
    var resonances: [Resonance] { displayedSweep.resonances }

    /// The feedline read out of regularly spaced crossings. When this is present the
    /// crossings belong to the line, not to whatever is on the end of it.
    var feedline: FeedlineEstimate? {
        guard let estimate = displayedSweep.feedlineEstimate, estimate.isCredible else { return nil }
        return estimate
    }

    /// The measured sample nearest the minimum, for the marker on the chart.
    var bestMatch: MeasurementPoint? {
        guard let index = minimumSWR?.sampleIndex else { return nil }
        let points = displayedPoints
        return points.indices.contains(index) ? points[index] : nil
    }

    private func sweepName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "\(Int(startMegahertz))–\(Int(endMegahertz)) MHz  \(formatter.string(from: Date()))"
    }

    private func teardown() async {
        if let session { await session.stop() }
        await channel?.close()
        session = nil
        channel = nil
    }

    private func describe(_ error: any Error) -> String {
        switch error {
        case AnalyzerSession.SessionError.timedOut(let what):
            strings.noReply(what)
        case AnalyzerSession.SessionError.analyzerReportedError:
            strings.analyzerRefused
        case ChannelError.cannotOpen(let path, _):
            strings.cannotOpen(path)
        default:
            String(describing: error)
        }
    }
}
