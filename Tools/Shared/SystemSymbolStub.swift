// A stand-in for `SystemSymbol` (Layer/Model/SystemSymbol.swift), which asks UIKit whether a
// symbol exists. The screen harness compiles the A2UI importer and exporter and `A2UIIcons`,
// which use only `resolve(_:)` and `placeholder`; none of the scores depends on what a symbol
// resolves to, so a name is kept as it was given.
enum SystemSymbol {
    /// As the app's: drawn for a name nothing else fits.
    static let placeholder = "square.dashed"

    static func resolve(_ name: String) -> String { name }
}
