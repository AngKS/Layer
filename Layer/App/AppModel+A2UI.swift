import CoreGraphics
import Foundation
import SwiftUI

/// What an A2UI import made, and what it couldn't bring in as it was written, by reason. Kept in the view state of
/// whatever started the import, which shows it with `a2uiImportSheet(_:)` when it needs showing (F19).
struct A2UIImportReport: Identifiable, Equatable, Sendable {
    struct Group: Equatable, Sendable {
        var reason: A2UIDiagnostic.Reason
        var title: String
        var diagnostics: [A2UIDiagnostic]
    }

    let id: UUID
    /// The screens made, in the order their surfaces were first named.
    var screens: [TreeScreen.ID]
    /// One for each reason present, in `Reason.allCases` order, each holding that reason's diagnostics as they came.
    var groups: [Group]
    /// What is still wrong with the screens made after the fix and the layout, by kind, with the nodes it is said of.
    var unfixed: [UnfixedIssue: [UUID]]

    init(id: UUID = UUID(), screens: [TreeScreen.ID], diagnostics: [A2UIDiagnostic],
         unfixed: [UnfixedIssue: [UUID]] = [:]) {
        self.id = id
        self.screens = screens
        self.unfixed = unfixed
        let byReason = Dictionary(grouping: diagnostics, by: \.reason)
        groups = A2UIDiagnostic.Reason.allCases.compactMap { reason in
            byReason[reason].map { Group(reason: reason, title: Self.title(for: reason), diagnostics: $0) }
        }
    }

    /// Whether the person needs to see it: something was left out or stands in for what was written, or something
    /// still runs off its screen or doesn't fit, or no screen was made. A clean import says nothing: its screens are there to see.
    var needsShowing: Bool { screens.isEmpty || !groups.isEmpty || !unfixed.isEmpty }

    /// What a reason says, as the sheet's heading for its diagnostics.
    static func title(for reason: A2UIDiagnostic.Reason) -> String {
        switch reason {
        case .notVersion1: String(localized: "Only A2UI 1.0 is read")
        case .parseFailed: String(localized: "Couldn't be read as A2UI")
        case .duplicateID: String(localized: "IDs used twice")
        case .noCatalog: String(localized: "Catalogues Layer doesn't know")
        case .invalidComponent: String(localized: "Changed or left out to fit Layer")
        case .unknownComponent: String(localized: "Components Layer doesn't know")
        case .missingRoot: String(localized: "No root component")
        case .cycle: String(localized: "Components that hold themselves")
        case .unresolved: String(localized: "References to what isn't there")
        case .unreachable: String(localized: "Not reached from root")
        case .tooDeep: String(localized: "Nested too deeply")
        case .binding: String(localized: "Bound to data that wasn't sent")
        case .template: String(localized: "Repeats without their data")
        case .actionNotRun: String(localized: "Actions aren't run in Layer")
        case .functionNotRun: String(localized: "Functions aren't run in Layer")
        case .nearestKind: String(localized: "Shown as the nearest thing Layer has")
        }
    }
}

extension AppModel {
    /// Imported and laid out off the main actor, then committed as new screens in one step ("Import A2UI"), as
    /// call 18 says. Trusts Layer's look, so a surface carrying Layer's name and deviceID keeps them; the device
    /// resolves through `settings.device(named:)`, and is the new-screen device when unknown here (F3). No screen
    /// means no step. The caller keeps the report in its own view state, not in AppModel (F19).
    ///
    /// The text is decoded only by the importer, through its guarded entry point (F1), which refuses text larger than
    /// `A2UIImporter.maximumBytes`. The screens go side by side, the first with its top-left corner at `point` (in
    /// canvas points) when there is one, else where new screens go, and are shown, not selected. Each is named as its
    /// surface names it, else from its first title, either on one line of at most 40 characters, else "A2UI Screen".
    func importA2UI(_ data: Data, near point: CGPoint? = nil) async -> A2UIImportReport {
        let settings = store.tree.settings
        let prepared = await Task.detached { Self.preparedA2UI(data, settings: settings) }.value
        return await commitA2UI(prepared, near: point)
    }

    /// A file of A2UI, as `importA2UI(_:near:)` imports text, all of it off the main actor: its size is read first, and
    /// a file larger than Layer reads A2UI (`A2UIImporter.maximumBytes`) isn't read at all; the report says so. Then
    /// it is read, imported and laid out, and committed. One that can't be read says so too. A file picked from
    /// outside the app can be read only while it is accessed, so all of that is done inside the access.
    func importA2UI(contentsOf url: URL, near point: CGPoint? = nil) async -> A2UIImportReport {
        let settings = store.tree.settings
        let read = await Task.detached { () -> FileRead in
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > A2UIImporter.maximumBytes {
                return .refused(A2UIImporter.tooLarge)
            }
            guard let data = try? Data(contentsOf: url) else {
                return .refused(A2UIDiagnostic(reason: .parseFailed, message: "\(url.lastPathComponent) couldn't be read."))
            }
            return .prepared(Self.preparedA2UI(data, settings: settings))
        }.value
        switch read {
        case .prepared(let prepared): return await commitA2UI(prepared, near: point)
        case .refused(let why): return A2UIImportReport(screens: [], diagnostics: [why])
        }
    }

    /// A file of A2UI as `importA2UI(contentsOf:near:)` reads it: imported and laid out, or refused unimported.
    private enum FileRead: Sendable {
        case prepared(PreparedA2UI)
        case refused(A2UIDiagnostic)
    }

    /// A2UI imported and laid out off the main actor for a design's settings, ready to be committed.
    struct PreparedA2UI: Sendable {
        fileprivate var imported: A2UIImport
        fileprivate var settings: CanvasSettings
        fileprivate var laidOut: [LaidOutImport]
    }

    /// `data` imported through the importer's guarded entry point, trusting Layer's look, with `settings`' tokens
    /// for its starting spacings, and each screen's root laid out for `settings`. Pure: for off the main actor.
    nonisolated static func preparedA2UI(_ data: Data, settings: CanvasSettings) -> PreparedA2UI {
        let imported = A2UIImporter.importJSON(data, tokens: settings.tokens, trustsLayerLook: true)
        return PreparedA2UI(imported: imported, settings: settings, laidOut: laidOut(imported.screens, settings: settings))
    }

    /// The second half of `importA2UI`: the prepared screens placed and added in one step. When the design's settings
    /// are no longer those they were laid out for (its tokens, its devices, the new-screen device), they are laid
    /// out again for the settings now, still off the main actor, before anything is committed.
    func commitA2UI(_ prepared: PreparedA2UI, near point: CGPoint? = nil) async -> A2UIImportReport {
        let imported = prepared.imported
        var settings = prepared.settings
        var laidOut = prepared.laidOut
        while settings != store.tree.settings {
            settings = store.tree.settings
            laidOut = await Task.detached { [settings, screens = imported.screens] in
                Self.laidOut(screens, settings: settings)
            }.value
        }
        guard !isClosed, !laidOut.isEmpty else { return A2UIImportReport(screens: [], diagnostics: imported.diagnostics) }

        // Side by side: each after the one before, moved right past any screen already there.
        var screens: [TreeScreen] = []
        var previous: CGRect?
        for (surface, made) in zip(imported.screens, laidOut) {
            let near = previous.map { CGPoint(x: $0.maxX + 60, y: $0.minY) } ?? point
            let placement = DesignActions.placementForNewScreen(made.device, in: self, near: near)
            var screen = TreeScreen(name: Self.name(of: surface), origin: placement.origin, scale: placement.scale,
                                    deviceID: made.device == .iPhone ? nil : made.device.id)
            // Set after: `init` keeps a root to a built-in device only, and this one is laid out for the design's own.
            screen.root = made.root
            screens.append(screen)
            previous = placement.canvasRect(for: CGRect(origin: .zero, size: made.device.size))
        }

        // Its own step, even in the middle of a drag, which goes on as its own (M3).
        let edit = store.beginEditOfItsOwn(by: .app)
        store.name(edit, String(localized: "Import A2UI"))
        let added = withAnimation(.smooth(duration: 0.3)) {
            store.act(for: edit) { store.addLaidOutScreens(screens) }
        }
        store.endEdit(edit)

        // A screen the design can't take is said, with why, as the importer says what it leaves out.
        var diagnostics = imported.diagnostics
        var unfixed: [UnfixedIssue: [UUID]] = [:]
        for (made, screen) in zip(laidOut, screens) where added.contains(screen.id) {
            unfixed.merge(made.unfixed) { $0 + $1 }
        }
        for (surface, (made, screen)) in zip(imported.screens, zip(laidOut, screens)) where !added.contains(screen.id) {
            diagnostics.append(A2UIDiagnostic(
                reason: .invalidComponent,
                message: "Surface \(surface.surfaceID) isn't imported: \(Self.whyRefused(screen.root, on: made.device))."))
        }
        if let shown = CanvasSelection(added.map(CanvasSelection.screen)) {
            DesignActions.reveal(shown, in: self, selecting: false)
        }
        return A2UIImportReport(screens: added, diagnostics: diagnostics, unfixed: unfixed)
    }

    /// An imported screen's root, laid out on its device.
    fileprivate struct LaidOutImport: Sendable {
        var device: DeviceFrame
        var root: LayerNode
        /// What the fix and the layout left wrong in it.
        var unfixed: [UnfixedIssue: [UUID]]
    }

    /// Each imported screen's root laid out as the rules would lay it out on its screen: on the surface's own device
    /// when it names one this design has (Layer's own export), else on the design's new-screen device (F3). A device of
    /// the design's own that can't be used (`DeviceFrame.problems`), which a file can hold, lays nothing out: the store
    /// refuses a screen on it, and the report says why (`whyRefused(_:on:)`).
    nonisolated private static func laidOut(_ screens: [A2UIImport.Screen], settings: CanvasSettings) -> [LaidOutImport] {
        screens.map { screen in
            let named = screen.deviceID.map(settings.device(named:))
            let device = named.flatMap { $0.id == screen.deviceID ? $0 : nil } ?? settings.sketchDevice
            guard device.problems.isEmpty else { return LaidOutImport(device: device, root: screen.root, unfixed: [:]) }
            let made = TreeRules.laidOutReporting(screen.root, deviceID: device == .iPhone ? nil : device.id,
                                                  settings: settings, previous: nil)
            return LaidOutImport(device: device, root: made.root,
                                 unfixed: UnfixedIssue.found(in: made.root, on: device, diagnostics: made.diagnostics))
        }
    }

    /// Why the design refused a screen's root on `device`, as `addLaidOutScreens` refuses one: its device can't be used,
    /// it holds what a screen can't, or there is no room for it.
    private static func whyRefused(_ root: LayerNode, on device: DeviceFrame) -> String {
        if !device.problems.isEmpty {
            return "its screen is for the device “\(device.name)”, which can't be used"
        }
        if TreeEdit.levels(below: root) > TreeRules.maximumDepth {
            return "its screen is nested more than \(TreeRules.maximumDepth) deep, which a screen can't hold"
        }
        if TreeEdit.holds(root, where: { !$0.kind.belongsOnScreens }) {
            return "its screen holds a sticky note or a drawing, which a screen can't hold"
        }
        return "its screen would take this design to more than \(TreeRules.maximumNodes.formatted()) things"
    }

    /// The name the surface gives its screen (Layer's own export), else its first title's words, either made one line
    /// of at most 40 characters (`screenName(from:)`), else "A2UI Screen".
    private static func name(of screen: A2UIImport.Screen) -> String {
        screen.name.flatMap(screenName(from:)) ?? firstTitle(in: screen.root).flatMap { screenName(from: $0.content.text) }
            ?? String(localized: "A2UI Screen")
    }

    /// Words as a screen's name: on one line, each run of spaces, tabs and line breaks made one space, and at most 40
    /// characters of them. Nil when there are none.
    nonisolated static func screenName(from words: String) -> String? {
        let line = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = String(line.prefix(40)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The first title in reading order.
    private static func firstTitle(in node: LayerNode) -> LayerNode? {
        for child in node.children {
            if child.kind == .title { return child }
            if let found = firstTitle(in: child) { return found }
        }
        return nil
    }
}
