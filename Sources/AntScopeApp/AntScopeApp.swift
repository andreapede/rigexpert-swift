import AntScopeCore
import AntScopeIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct AntScopeApp: App {
    var body: some Scene {
        WindowGroup("AntScope") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 640)
    }
}

/// Wraps a finished sweep so the system save panel can write it as Touchstone.
struct TouchstoneDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]

    let sweep: Sweep?

    init(sweep: Sweep?) {
        self.sweep = sweep
    }

    init(configuration: ReadConfiguration) throws {
        sweep = nil
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let sweep else { return FileWrapper(regularFileWithContents: Data()) }
        let text = TouchstoneFile(
            points: sweep.points, referenceImpedance: sweep.referenceImpedance
        ).serialized()
        return FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
