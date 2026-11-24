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
        /// A file larger than Layer reads A2UI (`A2UIImporter.maximumBytes`): nothing has read it.
        case tooLarge
    }

    /// The library's things among `strings` when there are any, else the first text that reads as A2UI, else nil.
    /// A2UI is told by `A2UIImporter.looksLikeA2UI`, a look at the first character: nothing here decodes it. Only
    /// `AppModel.importA2UI` does, through the importer's guarded entry point (F1).
    static func payload(of strings: [String]) -> Payload? {
        let assets = strings.filter { AssetLibrary.asset(id: $0) != nil }
        if !assets.isEmpty { return .assets(assets) }
        return strings.first(where: A2UIImporter.looksLikeA2UI).map { .a2ui(Data($0.utf8)) }
    }

    /// What dropped items bring: what their texts bring, as `payload(of:)` reads them, or else, when one was a file too
    /// large to read, `.tooLarge`.
    static func payload(ofDropped items: [DroppedText]) -> Payload? {
        if let payload = payload(of: items.compactMap(\.text)) { return payload }
        return items.contains(where: \.isTooLarge) ? .tooLarge : nil
    }

    /// Text dropped on the canvas: a `.json` file's, or text itself, which is what the library's things are dragged
    /// as. The file comes first, so that a JSON file is read as its contents.
    struct DroppedText: Transferable {
        /// The text; nil for a file larger than Layer reads A2UI, which is left unread.
        let text: String?

        var isTooLarge: Bool { text == nil }

        init(text: String) {
            self.text = text
        }

        /// A dropped file's text. Its size is read first: a file larger than Layer reads A2UI
        /// (`A2UIImporter.maximumBytes`) isn't read at all.
        init(file: URL) throws {
            if let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > A2UIImporter.maximumBytes {
                text = nil
            } else {
                text = try String(contentsOf: file, encoding: .utf8)
            }
        }

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .json) { received in
                try DroppedText(file: received.file)
            }
            ProxyRepresentation(importing: { (text: String) in DroppedText(text: text) })
        }
    }
}
