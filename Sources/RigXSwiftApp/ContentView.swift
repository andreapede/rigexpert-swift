import RigXCore
import RigXTransport
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = AnalyzerModel()
    @State private var isExporting = false
    @State private var isImportingCalibration = false
    @State private var isImportingSweep = false
    @State private var chartKind: ChartKind = .swr
    /// Frequency under the pointer, in MHz. Nil when the pointer is elsewhere.
    @State private var cursorFrequency: Double?

    private var s: Strings { model.strings }

    enum ChartKind: String, CaseIterable, Identifiable {
        case swr = "SWR"
        case impedance = "R / X"
        case smith = "Smith"
        case tdr = "TDR"
        var id: Self { self }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
        .fileImporter(
            isPresented: $isImportingSweep,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.loadSweeps(from: urls) }
        }
        .fileImporter(
            isPresented: $isImportingCalibration,
            allowedContentTypes: [.json]
        ) { result in
            if case .success(let url) = result { model.loadCalibration(from: url) }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: TouchstoneDocument(sweep: model.sweep),
            contentType: .data,
            defaultFilename: "sweep.s1p"
        ) { result in
            if case .failure(let error) = result {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var sidebar: some View {
        Form {
            Section(s.traces) {
                Picker(selection: $model.selection) {
                    Text(s.liveTrace).tag(AnalyzerModel.Selection.live)
                    ForEach(model.loadedTraces) { trace in
                        Text(trace.name).tag(AnalyzerModel.Selection.loaded(trace.id))
                    }
                } label: { EmptyView() }
                .pickerStyle(.inline)
                .labelsHidden()

                ForEach($model.loadedTraces) { $trace in
                    HStack {
                        Toggle(isOn: $trace.isVisible) {
                            Label {
                                Text(trace.name).lineLimit(1)
                            } icon: {
                                Circle()
                                    .fill(SWRChart.palette(trace.colorIndex))
                                    .frame(width: 8, height: 8)
                            }
                        }
                        Spacer()
                        Button {
                            model.removeTrace(trace.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button(s.openSweep, systemImage: "doc.badge.plus") { isImportingSweep = true }
                if !model.loadedTraces.isEmpty {
                    Text(s.comparisonNote).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(s.connection) {
                Picker(s.port, selection: $model.selectedPort) {
                    ForEach(model.ports) { port in
                        Text(port.name).tag(Optional(port.path))
                    }
                }
                .disabled(model.connection.isConnected)

                Picker(s.baud, selection: $model.baudRate) {
                    Text(s.baudBridge).tag(Int32(115200))
                    Text(s.baudDirect).tag(Int32(38400))
                }
                .disabled(model.connection.isConnected)

                HStack {
                    Button(s.refresh, systemImage: "arrow.clockwise") { model.refreshPorts() }
                        .disabled(model.connection.isConnected)
                    Spacer()
                    connectButton
                }
            }

            if case .connected(let version) = model.connection {
                Section(s.analyzer) {
                    LabeledContent(s.model, value: version.model)
                    LabeledContent(s.firmware, value: version.firmware)
                    if let range = version.profile?.frequencyRange {
                        LabeledContent(s.band, value: "\(range.lowerBound) – \(range.upperBound)")
                    }
                }
            }

            Section(s.calibration) {
                if let calibration = model.calibration {
                    Toggle(s.applyCorrection, isOn: $model.applyCalibration)
                        .onChange(of: model.applyCalibration) { model.recomputeCable() }
                    Toggle(s.showRawTrace, isOn: $model.showRawTrace)
                        .disabled(!model.applyCalibration)
                    if let range = calibration.frequencyRange {
                        LabeledContent(s.band, value: "\(range.lowerBound) – \(range.upperBound)")
                    }
                    LabeledContent(s.points, value: "\(calibration.points.count)")
                    LabeledContent(s.date, value: calibration.date.formatted(date: .abbreviated, time: .shortened))
                    if model.sweepExceedsCalibration {
                        Label(
                            s.outOfCalibratedBand,
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .font(.caption)
                    }
                    Button(s.remove, role: .destructive) { model.clearCalibration() }
                } else {
                    Text(s.noCalibration)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(s.createOneWith)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(s.loadFile, systemImage: "folder") { isImportingCalibration = true }
            }

            Section(s.sweep) {
                LabeledContent(s.from) {
                    TextField("MHz", value: $model.startMegahertz, format: .number)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(s.to) {
                    TextField("MHz", value: $model.endMegahertz, format: .number)
                        .multilineTextAlignment(.trailing)
                }
                Picker(s.points, selection: $model.points) {
                    ForEach([50, 100, 200, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
                }

                Button {
                    Task { await model.runSweep() }
                } label: {
                    Label(model.isSweeping ? s.sweeping : s.startSweep, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connection.isConnected || model.isSweeping)
            }

            if chartKind == .tdr {
                Section {
                    Picker(selection: $model.tdrWindow) {
                        ForEach(TDRWindow.allCases, id: \.self) { Text($0.name).tag($0) }
                    } label: {
                        // The label carries the caveat: the transform is new, and the
                        // window is the control that most changes what it shows.
                        Text("\(s.window) \(s.experimental)")
                    }
                    LabeledContent(s.velocityFactor) {
                        TextField("VF", value: $model.tdrVelocityFactor, format: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    if let response = model.tdr {
                        LabeledContent(s.resolution, value: String(format: "%.2f m", response.resolution))
                    }
                    Text(s.tdrBandwidthNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("\(s.tdr) \(s.experimental)")
                }
            }

            if let feedline = model.feedline {
                Section(s.feedline) {
                    Text(s.feedlineExplanation(feedline.crossingCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent(s.spacing, value: String(format: "%.2f MHz", feedline.crossingSpacing.megahertz))
                    LabeledContent(s.electricalLength, value: String(format: "%.3f m", feedline.electricalLength))
                    LabeledContent(s.physicalLength) {
                        TextField("m", value: $model.knownCableLength, format: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    if model.knownCableLength > 0 {
                        LabeledContent(
                            s.velocityFactor,
                            value: String(format: "%.4f", feedline.velocityFactor(physicalLength: model.knownCableLength))
                        )
                    } else {
                        LabeledContent(s.atVelocityFactor("0.66"), value: String(format: "%.3f m", feedline.physicalLength(velocityFactor: 0.66)))
                    }
                    LabeledContent(s.irregularity, value: String(format: "%.1f%%", feedline.irregularity * 100))
                }
            }

            if let cable = model.cable, cable.isCredible {
                Section(s.cable) {
                    LabeledContent(s.delay, value: String(format: "%.2f ns", cable.roundTripDelay * 1e9))
                    LabeledContent(s.electricalLength, value: String(format: "%.3f m", cable.electricalLength))
                    LabeledContent(s.physicalLength) {
                        TextField("m", value: $model.knownCableLength, format: .number)
                            .multilineTextAlignment(.trailing)
                    }
                    if model.knownCableLength > 0 {
                        LabeledContent(
                            s.velocityFactor,
                            value: String(format: "%.4f", cable.velocityFactor(physicalLength: model.knownCableLength))
                        )
                    } else {
                        LabeledContent(s.atVelocityFactor("0.66"), value: String(format: "%.3f m", cable.physicalLength(velocityFactor: 0.66)))
                        LabeledContent(s.atVelocityFactor("0.80"), value: String(format: "%.3f m", cable.physicalLength(velocityFactor: 0.80)))
                    }
                    LabeledContent(s.residual, value: String(format: "%.5f", cable.residual))
                }
            }

            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var connectButton: some View {
        Button {
            Task {
                if model.connection.isConnected {
                    await model.disconnect()
                } else {
                    await model.connect()
                }
            }
        } label: {
            switch model.connection {
            case .connecting: Text(s.connecting)
            case .connected: Text(s.disconnect)
            case .disconnected: Text(s.connect)
            }
        }
        .disabled(model.selectedPort == nil || model.connection == .connecting)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if model.isSweeping {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
            }

            charts
                .padding()

            Divider()
            if let cursorPoint {
                cursorReadout(cursorPoint)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.07))
                Divider()
            }
            summary
                .padding(.horizontal)
                .padding(.vertical, 10)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(s.chart, selection: $chartKind) {
                    ForEach(ChartKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
            ToolbarItem(placement: .automatic) {
                // Icon only and unlabelled: switching language is done once and then
                // never again, so it should not compete with the controls that are.
                Menu {
                    Picker(s.uiLanguage, selection: $model.language) {
                        ForEach(Language.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "globe")
                }
                .menuIndicator(.hidden)
                .help(s.uiLanguage)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(s.exportTouchstone, systemImage: "square.and.arrow.up") {
                    isExporting = true
                }
                .disabled(model.sweep == nil)
            }
        }
    }

    @ViewBuilder
    private var charts: some View {
        switch chartKind {
        case .swr:
            SWRChart(
                others: model.visibleTraces
                    .filter { !$0.isSelected }
                    .map { (name: $0.name, points: $0.points, colorIndex: $0.colorIndex) },
                points: model.displayedPoints,
                bestMatch: model.bestMatch,
                rawPoints: model.showRawTrace && model.activeCalibration != nil ? model.rawPoints : [],
                cursorFrequency: cursorFrequency,
                strings: s
            )
            .chartCursor(frequency: $cursorFrequency)
        case .impedance:
            ImpedanceChart(points: model.displayedPoints, cursorFrequency: cursorFrequency, strings: s)
                .chartCursor(frequency: $cursorFrequency)
        case .tdr:
            TDRChart(response: model.tdr, strings: s)
        case .smith:
            SmithChart(
                points: model.displayedPoints,
                referenceImpedance: model.displayedSweep.referenceImpedance,
                highlighted: model.bestMatch,
                cursor: cursorPoint,
                feedlineDetected: model.feedline != nil,
                strings: s
            )
        }
    }

    /// The measured sample nearest the pointer.
    private var cursorPoint: MeasurementPoint? {
        guard let cursorFrequency else { return nil }
        return model.displayedPoints.min {
            abs($0.frequency.megahertz - cursorFrequency) < abs($1.frequency.megahertz - cursorFrequency)
        }
    }

    private func cursorReadout(_ point: MeasurementPoint) -> some View {
        let gamma = point.reflection(referenceImpedance: model.displayedSweep.referenceImpedance)
        return HStack(spacing: 24) {
            readout(s.cursor, String(format: "%.4f MHz", point.frequency.megahertz))
            readout(s.swr, gamma.swr.map { String(format: "%.3f", $0) } ?? "—")
            readout("R", String(format: "%.2f Ω", point.impedance.resistance))
            readout("X", String(format: "%.2f Ω", point.impedance.reactance))
            readout("|Z|", String(format: "%.2f Ω", point.impedance.magnitude))
            readout("|Γ|", String(format: "%.4f", gamma.magnitude))
            readout("fase Γ", String(format: "%.1f°", gamma.phaseDegrees))
            Spacer()
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let best = model.bestMatch, let minimum = model.minimumSWR {
            let gamma = best.reflection(referenceImpedance: model.displayedSweep.referenceImpedance)
            HStack(spacing: 24) {
                readout(
                    s.minimumSWR,
                    String(format: "%.3f  a %.4f MHz", minimum.swr, minimum.frequency.megahertz)
                )
                readout(s.resonance, resonanceText)
                readout("R", String(format: "%.2f Ω", best.impedance.resistance))
                readout("X", String(format: "%.2f Ω", best.impedance.reactance))
                readout(s.returnLoss, String(format: "%.1f dB", gamma.returnLossDecibels))
                readout(s.swrSpread, swrSpread)
                Spacer()
                qualityReadout
            }
        } else {
            Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The reactance crossing — unless there are so many that they describe the feedline,
    /// in which case naming one of them as "the resonance" would be a diagnosis, and a
    /// wrong one.
    private var resonanceText: String {
        if let feedline = model.feedline {
            return s.crossingsAreTheLine(feedline.crossingCount)
        }
        guard let resonance = model.resonance else { return s.noResonance }
        return String(
            format: "%.4f MHz  ·  R %.1f Ω",
            resonance.frequency.megahertz, resonance.resistance
        )
    }

    /// The spread of SWR across the sweep. A flat trace on a well-chosen axis still
    /// leaves the question "is it really constant?" — this answers it numerically.
    private var swrSpread: String {
        // Samples that come back all but perfectly reflective are the ones the analyzer
        // could not measure; including them puts an SWR of several million in a readout
        // meant to say how flat the curve is.
        let z0 = model.displayedSweep.referenceImpedance
        let values = model.displayedPoints
            .map { $0.reflection(referenceImpedance: z0) }
            .filter { $0.magnitude < 0.999 }
            .compactMap(\.swr)
        guard let low = values.min(), let high = values.max() else { return "—" }
        return high >= 100
            ? String(format: "%.3f – >100", low)
            : String(format: "%.3f – %.2f", low, high)
    }

    /// Point count, and how many of those points the instrument actually managed to
    /// measure. Silence about lost samples would be the wrong default: a sweep taken at
    /// the edge of the analyzer's range can drop a handful and still look plausible.
    @ViewBuilder
    private var qualityReadout: some View {
        let quality = model.displayedSweep.quality
        if quality.isClean {
            readout(s.points, "\(quality.sampleCount)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.points).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Text("\(quality.sampleCount)").font(.system(.body, design: .monospaced))
                    Image(systemName: quality.deservesRepeating
                          ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                    Text("\(quality.faultCount) \(s.lost)")
                        .font(.system(.body, design: .monospaced))
                }
                .foregroundStyle(quality.deservesRepeating ? .orange : .secondary)
            }
            .help(faultDescription(quality))
        }
    }

    private func faultDescription(_ quality: SweepQuality) -> String {
        var lines: [String] = []
        if !quality.saturated.isEmpty {
            let list = quality.saturated.prefix(6).map { String(format: "%.2f", $0.megahertz) }
                .joined(separator: ", ")
            lines.append(s.lostSamplesDetail(list, more: quality.saturated.count > 6))
        }
        if !quality.malformed.isEmpty {
            lines.append(s.malformedSamples(quality.malformed.count))
        }
        lines.append(s.lostSamplesExplanation)
        return lines.joined(separator: "\n")
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}
