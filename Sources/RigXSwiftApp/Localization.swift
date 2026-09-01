import Foundation
import SwiftUI

/// The interface language, switchable while the app runs.
///
/// Deliberately not the system's `.strings` bundles: those are resolved once at launch,
/// and changing language would mean quitting. A table in code costs a little duplication
/// and switches instantly, which is what a two-language utility actually needs.
enum Language: String, CaseIterable, Identifiable {
    case italian
    case english

    var id: Self { self }

    var name: String {
        switch self {
        case .italian: "Italiano"
        case .english: "English"
        }
    }

    /// Follows the system on first launch, then whatever the operator chose.
    static var systemDefault: Language {
        Locale.preferredLanguages.first?.hasPrefix("it") == true ? .italian : .english
    }
}

/// Every string the interface shows, in both languages.
///
/// Properties rather than keyed lookups: a missing translation is a compile error, not a
/// string that silently prints its own key.
struct Strings {
    let language: Language

    private func pick(_ italian: String, _ english: String) -> String {
        language == .italian ? italian : english
    }

    // Connection
    var connection: String { pick("Collegamento", "Connection") }
    var port: String { pick("Porta", "Port") }
    var baud: String { pick("Baud", "Baud") }
    var baudBridge: String { pick("115200 · bridge Arduino", "115200 · Arduino bridge") }
    var baudDirect: String { pick("38400 · diretto", "38400 · direct") }
    var refresh: String { pick("Aggiorna", "Refresh") }
    var connect: String { pick("Collega", "Connect") }
    var connecting: String { pick("Collegamento…", "Connecting…") }
    var disconnect: String { pick("Disconnetti", "Disconnect") }

    // Analyzer
    var analyzer: String { pick("Analizzatore", "Analyzer") }
    var model: String { pick("Modello", "Model") }
    var firmware: String { pick("Firmware", "Firmware") }
    var band: String { pick("Banda", "Range") }

    // Calibration
    var calibration: String { pick("Calibrazione", "Calibration") }
    var applyCorrection: String { pick("Applica correzione", "Apply correction") }
    var showRawTrace: String { pick("Mostra traccia grezza", "Show raw trace") }
    var points: String { pick("Punti", "Points") }
    var date: String { pick("Data", "Date") }
    var remove: String { pick("Rimuovi", "Remove") }
    var noCalibration: String { pick("Nessuna calibrazione caricata.", "No calibration loaded.") }
    var createOneWith: String {
        pick("Creane una con  rigx-probe calibrate", "Create one with  rigx-probe calibrate")
    }
    var loadFile: String { pick("Carica file…", "Load file…") }
    var outOfCalibratedBand: String {
        pick("Lo sweep esce dalla banda calibrata: fuori range la correzione è tenuta ferma all'estremo più vicino.",
             "The sweep runs past the calibrated range: outside it the correction is held at the nearest end.")
    }

    // Feedline
    var feedline: String { pick("Linea di discesa", "Feedline") }
    func feedlineExplanation(_ count: Int) -> String {
        pick("\(count) attraversamenti X=0 a passo regolare: appartengono alla linea, non all'antenna. Per la risonanza guarda lo SWR minimo, che il cavo non sposta.",
             "\(count) evenly spaced X=0 crossings: they belong to the line, not the antenna. For resonance read the lowest SWR, which the cable does not move.")
    }
    var spacing: String { pick("Passo", "Spacing") }
    var electricalLength: String { pick("Lunghezza elettrica", "Electrical length") }
    var physicalLength: String { pick("Lunghezza fisica", "Physical length") }
    var velocityFactor: String { pick("Fattore di velocità", "Velocity factor") }
    var irregularity: String { pick("Irregolarità", "Irregularity") }
    func atVelocityFactor(_ factor: String) -> String {
        pick("con VF \(factor)", "at VF \(factor)")
    }

    // Cable
    var cable: String { pick("Cavo", "Cable") }
    var delay: String { pick("Ritardo", "Delay") }
    var residual: String { pick("Residuo", "Residual") }

    // Sweep
    var sweep: String { pick("Sweep", "Sweep") }
    var from: String { pick("Da", "From") }
    var to: String { pick("A", "To") }
    var startSweep: String { pick("Avvia sweep", "Start sweep") }
    var sweeping: String { pick("Misura in corso…", "Measuring…") }
    var exportTouchstone: String { pick("Esporta .s1p", "Export .s1p") }

    // Readouts
    var cursor: String { pick("Cursore", "Cursor") }
    var swr: String { pick("SWR", "SWR") }
    var minimumSWR: String { pick("SWR minimo", "Lowest SWR") }
    /// The joining word inside a formatted readout. Easy to leave behind in a format
    /// string, where it hides from any search for user-visible text.
    func swrAt(_ swr: Double, megahertz: Double) -> String {
        pick(String(format: "%.3f  a %.4f MHz", swr, megahertz),
             String(format: "%.3f  at %.4f MHz", swr, megahertz))
    }
    var resonance: String { pick("Risonanza (X=0)", "Resonance (X=0)") }
    var noResonance: String { pick("nessuna nella banda", "none in this range") }
    func crossingsAreTheLine(_ count: Int) -> String {
        pick("\(count) attraversamenti · è la linea", "\(count) crossings · that is the line")
    }
    var returnLoss: String { pick("Return loss", "Return loss") }
    var swrSpread: String { pick("Escursione SWR", "SWR spread") }
    var lost: String { pick("persi", "lost") }
    func lostSamplesDetail(_ list: String, more: Bool) -> String {
        pick("|Γ| ≥ 1 a \(list) MHz\(more ? " …" : "")",
             "|Γ| ≥ 1 at \(list) MHz\(more ? " …" : "")")
    }
    func malformedSamples(_ count: Int) -> String {
        pick("\(count) campioni non numerici", "\(count) samples that are not numbers")
    }
    var lostSamplesExplanation: String {
        pick("Campioni che l'analizzatore non è riuscito a misurare: riflessione superiore all'unità, che un carico passivo non può produrre.",
             "Samples the analyzer could not measure: a reflection greater than unity, which no passive load can produce.")
    }

    // Charts
    var noMeasurement: String { pick("Nessuna misura", "No measurement") }
    var connectAndSweep: String {
        pick("Collegati all'analizzatore e avvia uno sweep.", "Connect the analyzer and start a sweep.")
    }
    var frequency: String { pick("Frequenza", "Frequency") }
    var chart: String { pick("Grafico", "Chart") }
    var uiLanguage: String { pick("Lingua", "Language") }

    // TDR
    var tdr: String { pick("TDR", "TDR") }

    // Traces
    var traces: String { pick("Tracce", "Traces") }
    var liveTrace: String { pick("Misura", "Live") }
    var openSweep: String { pick("Apri .s1p…", "Open .s1p…") }
    var selectedTraceAlwaysShown: String {
        pick("La traccia selezionata è sempre disegnata: per nasconderla, selezionane un'altra.",
             "The selected trace is always drawn: to hide it, select another one.")
    }
    var comparisonNote: String {
        pick("Il confronto si vede sul grafico SWR; gli altri mostrano la traccia selezionata. Ai file caricati non viene applicata la calibrazione: potrebbero esserlo già.",
             "The comparison shows on the SWR chart; the others draw the selected trace. Loaded files are shown as saved — no calibration is applied, since they may already carry one.")
    }
    var experimental: String { pick("(sperimentale)", "(experimental)") }
    var window: String { pick("Finestra", "Window") }
    var distance: String { pick("Distanza", "Distance") }
    var metres: String { pick("metri", "metres") }
    var resolution: String { pick("Risoluzione", "Resolution") }
    var tdrNeedsUniformSweep: String {
        pick("Il TDR richiede uno sweep su griglia uniforme con almeno 8 punti.",
             "TDR needs a sweep on a uniform grid with at least 8 points.")
    }
    func tdrCaption(resolution: Double, window: String, velocityFactor: Double) -> String {
        pick(String(format: "risoluzione %.2f m — un picco indicato a una certa distanza significa ± %.2f m · finestra %@ · VF %.3f",
                    resolution, resolution / 2, window, velocityFactor),
             String(format: "resolution %.2f m — a peak marked at a distance means ± %.2f m · %@ window · VF %.3f",
                    resolution, resolution / 2, window, velocityFactor))
    }
    var tdrBandwidthNote: String {
        pick("La risoluzione dipende solo dalla banda misurata: per vedere cavi corti serve arrivare in alto in frequenza.",
             "Resolution depends only on the measured bandwidth: seeing short cables means sweeping high.")
    }

    // Smith chart
    var smithShort: String { pick("corto", "short") }
    var smithOpen: String { pick("aperto", "open") }
    var smithRings: String {
        pick("cerchi verdi tratteggiati: SWR 1,5 · 2 · 3 — più vicino al centro, meglio adattato",
             "dashed green rings: SWR 1.5 · 2 · 3 — closer to the centre is better matched")
    }
    var smithHalves: String {
        pick("metà superiore induttiva (X > 0), inferiore capacitiva (X < 0)",
             "upper half inductive (X > 0), lower half capacitive (X < 0)")
    }
    var smithHalvesMeaning: String {
        pick(" — sopra l'asse antenna elettricamente lunga, sotto corta",
             " — above the axis the antenna is electrically long, below it short")
    }
    var smithHalvesRotated: String {
        pick(" — ma con la discesa di mezzo NON indicano antenna lunga o corta: è il cavo che ruota la traccia",
             " — but with a feedline in between they do NOT mean long or short: the cable rotates the trace")
    }

    // Errors
    func noReply(_ what: String) -> String {
        pick("Nessuna risposta dall'analizzatore (\(what)). Controlla porta, baud rate e cablaggio.",
             "No reply from the analyzer (\(what)). Check the port, the baud rate and the wiring.")
    }
    var analyzerRefused: String {
        pick("L'analizzatore ha rifiutato la richiesta.", "The analyzer refused the request.")
    }
    func cannotOpen(_ path: String) -> String {
        pick("Impossibile aprire \(path).", "Cannot open \(path).")
    }
    var calibrationUnreadable: String {
        pick("Calibrazione non leggibile", "Calibration could not be read")
    }
    var calibrationTooShort: String {
        pick("Il file di calibrazione non contiene abbastanza punti.",
             "The calibration file does not hold enough points.")
    }
}
