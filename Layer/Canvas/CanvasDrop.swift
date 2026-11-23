import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What a drop or a paste on the canvas brings: things from the library, by their ids, or A2UI written out (call 17).
enum CanvasDrop {
    enum Payload: Equatable {
        /// Library asset ids.
        case assets([String])
        /// A2UI text, as it was given: nothing has decoded it.
        case a2ui(Data)
    }

    /// The library's things among `strings` when there are any, else the first text that reads as A2UI, else nil.
    /// A2UI is told by `A2UIImporter.looksLikeA2UI`, a look at the first character: nothing here decodes it. Only
    /// `AppModel.importA2UI` does, through the importer's guarded entry point (F1).
    static func payload(of strings: [String]) -> Payload? {
        let assets = strings.filter { AssetLibrary.asset(id: $0) != nil }
        if !assets.isEmpty { return .assets(assets) }
        return strings.first(where: A2UIImporter.looksLikeA2UI).map { .a2ui(Data($0.utf8)) }
    }

    /// Text dropped on the canvas: a `.json` file's, or text itself, which is what the library's things are dragged
    /// as. The file comes first, so that a JSON file is read as its contents.
    struct DroppedText: Transferable {
        let text: String

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .json) { received in
                DroppedText(text: try String(contentsOf: received.file, encoding: .utf8))
            }
            ProxyRepresentation(importing: { (text: String) in DroppedText(text: text) })
        }
    }
}
