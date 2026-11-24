import CoreGraphics
import Foundation
@testable import Layer

// PROJECTION: deleted in plan 6
// The export as tests written for elements call it (call 14). Each `DesignScreen`'s elements are
// lifted into a free root (`TreeLift`) and the tree is exported, so these tests show that a free
// screen's code is today's. No app code exports from the projection. The signatures and defaults
// are today's (F12).

// PROJECTION: deleted in plan 6
extension SwiftUICodeGenerator {
    /// A screen as the tree holds it, its root free and empty.
    private static func emptyScreen(_ screen: DesignScreen) -> TreeScreen {
        var tree = TreeScreen(name: screen.name, origin: screen.origin, scale: screen.scale, deviceID: screen.deviceID)
        tree.id = screen.id
        if let device = screen.resolvedDevice, device.isCustom { tree.keepRootToDevice(device) }
        tree.root.layout = .free
        return tree
    }

    /// The screens as a design's tree: each one's elements lifted into its free root, where they are.
    private static func design(of screens: [DesignScreen]) -> TreeContent {
        var content = TreeContent()
        for screen in screens {
            var tree = emptyScreen(screen)
            if let device = screen.resolvedDevice, device.isCustom, !content.settings.customDevices.contains(where: { $0.id == device.id }) {
                content.settings.customDevices.append(device)
            }
            // Lifted alone, so that an element shown on two screens is a node of each.
            var alone = TreeContent()
            alone.screens = [tree]
            TreeLift.give(TreeLift.nodes(from: screen.elements, host: .screen(screen.id), keeping: alone).nodes, to: &tree.root)
            content.screens.append(tree)
        }
        return content
    }

    static func fileName(for screen: DesignScreen) -> String {
        screen.typeName + ".swift"
    }

    static func fileName(for screen: DesignScreen, among screens: [DesignScreen]) -> String {
        (typeNames(for: screens)[screen.id] ?? screen.typeName) + ".swift"
    }

    static func typeNames(for screens: [DesignScreen]) -> [DesignScreen.ID: String] {
        typeNames(for: screens.map(emptyScreen))
    }

    static func code(for screen: DesignScreen, among screens: [DesignScreen], settings: CodeSettings = CodeSettings()) -> String {
        let content = design(of: screens.contains(where: { $0.id == screen.id }) ? screens : screens + [screen])
        let tree = content.screens.first { $0.id == screen.id }!
        return code(for: tree, in: Context(content), settings: settings)
    }

    static func code(for screen: DesignScreen, typeName: String? = nil, settings: CodeSettings = CodeSettings()) -> String {
        let content = design(of: [screen])
        var context = Context(content)
        context.typeNames[screen.id] = typeName ?? screen.typeName
        return code(for: content.screens[0], in: context, settings: settings)
    }

    static func files(for screens: [DesignScreen], settings: CodeSettings = CodeSettings()) -> [(name: String, source: String)] {
        files(for: design(of: screens), settings: settings)
    }
}

// PROJECTION: deleted in plan 6
extension GenerateSwiftUICodeIntent {
    /// The tree's call, for a screen of a design's projection.
    static func code(for screen: DesignScreen, in content: DesignContent) -> String {
        code(for: screen.id, in: content.tree) ?? ""
    }
}
