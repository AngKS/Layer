import A2UICore
import BasicCatalog
import CoreGraphics
import Foundation
import OrderedJSON

/// What an A2UI import brings in: one screen for each surface whose root can be resolved, and a
/// diagnostic for everything that couldn't be brought in as it was written.
struct A2UIImport: Sendable {
    struct Screen: Sendable {
        var surfaceID: String
        var root: LayerNode
        /// The screen's name and device, as Layer's export writes them in the surface's
        /// `createSurface.metadata.extensions.layer`; nil when the surface doesn't say.
        var name: String?
        var deviceID: String?
    }

    var screens: [Screen] = []
    var diagnostics: [A2UIDiagnostic] = []
}

/// Reads A2UI 1.0 into the tree (spec §6, "A2UI import"):
/// 1. The text is decoded only through `decodeJSON`, and each message is parsed on its own with
///    the SDK's `parseAll`, so one bad message doesn't stop the rest. Anything that isn't version
///    1.0 is refused.
/// 2. Each surface keeps its components by id, the last write of each winning, and its data model.
/// 3. The graph is walked from `root` over the child slots `GraphTopologyValidator.extractReferences`
///    finds. The walk collects every problem; the SDK's own validators stop at the first.
/// 4. Each component the walk reached is validated, strictly, against its catalogue with
///    `PayloadValidator`.
/// 5. Components map to nodes (the spec's table), and Layer's own look in
///    `@metadata.extensions.layer` wins over the mapping.
/// 6. The tree is fixed as every generated tree is, with `TreeValidator.fixGenerated`.
///
/// What a payload can make it do is bounded, however it's written: nesting (`maximumJSONDepth`),
/// data-model paths (`maximumPathSteps`, `maximumPathIndex`) and values (`maximumDataModelValues`),
/// nodes (5,000 for the whole import, as for a design) and the children it considers
/// (`maximumChildRequests`). Only components reached from a root are validated.
///
/// It is all plain values and the SDK's nonisolated, Sendable API, so it runs off the main actor.
/// Nothing is ever run: there is no processor and no action handler here. Actions, function
/// calls and checks stay inert data; each action and function call is reported.
enum A2UIImporter {
    /// The inert event Layer's own export gives a button. It isn't reported on import.
    static let layerActionName = "layer.none"

    /// How deep a component graph is read below its root, as A2UI's own validator allows.
    static let maximumGraphDepth = 50

    /// How deeply a payload's arrays and objects may nest. Decoding JSON goes one call deeper for
    /// each level, and off the main actor a thread has little stack, so a payload nested past this
    /// is refused before anything decodes it. Real A2UI stays far inside: the SDK refuses a
    /// message nested deeper than 50.
    static let maximumJSONDepth = 64

    /// How many steps a data-model path may take. Writing one goes a call deeper for each step.
    static let maximumPathSteps = 64

    /// The farthest into a list a data-model path may reach. Writing a path grows each list it
    /// passes through to the index it names, so one reaching further is skipped.
    static let maximumPathIndex = 1_000

    /// How many values the data models of one import may hold in all, the lists that paths
    /// grow counted too. Updates past it are skipped.
    static let maximumDataModelValues = 50_000

    /// How many children one import considers making, across every container and template,
    /// whether they're made or turned away. A component reached many times over asks for its
    /// children each time; past this, what is left isn't looked at.
    static let maximumChildRequests = 10 * TreeRules.maximumNodes

    /// Nonisolated; never throws. One screen per surface that has a resolvable root, and no more
    /// than 5,000 nodes in all, as a design holds.
    static func importJSON(_ data: Data) -> A2UIImport {
        let (items, read) = guardedMessages(from: data)
        var diagnostics = read
        let messages = parse(items, into: &diagnostics)
        var screens: [A2UIImport.Screen] = []
        var budget = ScreenBuilder.Budget(nodes: TreeRules.maximumNodes, childRequests: maximumChildRequests)
        for surface in gather(messages, into: &diagnostics) {
            guard budget.nodes > 0 else {
                diagnostics.append(A2UIDiagnostic(
                    reason: .invalidComponent,
                    message: "The import has \(TreeRules.maximumNodes) nodes already, so surface \(surface.id) and any after it aren't imported."))
                break
            }
            var builder = ScreenBuilder(surface: surface, budget: budget)
            if let root = builder.build() {
                screens.append(A2UIImport.Screen(surfaceID: surface.id, root: root, name: surface.name, deviceID: surface.deviceID))
            }
            diagnostics += builder.diagnostics
            budget = builder.budget
        }
        return A2UIImport(screens: screens, diagnostics: diagnostics)
    }
}

// MARK: - Reading the messages

extension A2UIImporter {
    /// JSON as Layer reads A2UI text: decoded, nested too deep to decode safely, or not JSON.
    enum Reading: Sendable {
        case value(OrderedJSON.JSONValue)
        case tooDeep
        case notJSON
    }

    /// The one way Layer decodes A2UI text, wherever it comes from (a file, a paste, a drop, a
    /// line a model streams): JSON, decoded only once its nesting is known to be within
    /// `maximumJSONDepth`. Decoding goes a call deeper for each level, and off the main actor a
    /// thread has little stack, so nothing that reads A2UI decodes it any other way.
    static func decodeJSON(_ data: Data) -> Reading {
        guard !nests(data, deeperThan: maximumJSONDepth) else { return .tooDeep }
        guard let value = try? JSONDecoder().decode(OrderedJSON.JSONValue.self, from: data) else { return .notJSON }
        return .value(value)
    }

    /// The A2UI messages in `data`, as JSON, each decoded as `decodeJSON` decodes: one message, an
    /// array of them or an object holding `messages` (as the official examples are written); or
    /// one message per line, as a model streams them. Read line by line, each line is checked on
    /// its own, so a line nested too deep, or a stray bracket, costs only that line: it's skipped,
    /// said so, and the lines round it are still read.
    static func guardedMessages(from data: Data) -> (messages: [OrderedJSON.JSONValue], diagnostics: [A2UIDiagnostic]) {
        var diagnostics: [A2UIDiagnostic] = []
        let messages = items(in: data, into: &diagnostics)
        return (messages, diagnostics)
    }

    /// Each message parsed on its own as A2UI 1.0, so one bad message doesn't stop the rest.
    fileprivate static func parse(_ items: [OrderedJSON.JSONValue], into diagnostics: inout [A2UIDiagnostic]) -> [AgentToRendererMessage] {
        var messages: [AgentToRendererMessage] = []
        for (index, item) in items.enumerated() {
            let place = "messages[\(index)]"
            guard let fields = item.objectValue else {
                diagnostics.append(A2UIDiagnostic(reason: .parseFailed, path: place, message: "A message must be a JSON object."))
                continue
            }
            guard fields["version"]?.stringValue == "1.0" else {
                let written = fields["version"].map { "is version \($0.stringValue ?? "\($0)")" } ?? "has no version"
                diagnostics.append(A2UIDiagnostic(
                    reason: .notVersion1, path: "\(place).version",
                    message: "This message \(written): only A2UI 1.0 can be imported."))
                continue
            }
            do {
                messages += try AgentToRendererMessage.parseAll(item, protocolVersion: .v10)
            } catch let error as A2UIValidationError {
                // The SDK reads each message as the first of its batch.
                let path = error.details.first.map { detail in
                    detail.path.hasPrefix("messages.0") ? place + detail.path.dropFirst("messages.0".count) : detail.path
                }
                diagnostics.append(A2UIDiagnostic(reason: .parseFailed, path: path ?? place, message: error.message))
            } catch {
                diagnostics.append(A2UIDiagnostic(reason: .parseFailed, path: place, message: error.localizedDescription))
            }
        }
        return messages
    }

    /// The messages as JSON (see `guardedMessages`). When the whole can't be read, as one value
    /// or because it nests too deep counted end to end, it's read line by line.
    private static func items(in data: Data, into diagnostics: inout [A2UIDiagnostic]) -> [OrderedJSON.JSONValue] {
        let whole = decodeJSON(data)
        switch whole {
        case .value(.array(let items)):
            return items
        case .value(let value):
            if case .object(let fields) = value { return fields["messages"]?.arrayValue ?? [value] }
            diagnostics.append(A2UIDiagnostic(reason: .parseFailed, message: "This JSON holds no A2UI messages."))
            return []
        case .tooDeep, .notJSON:
            break
        }
        // One message per line: lines end at a newline byte, which JSON never holds inside a
        // string. Each line's nesting is counted from nothing, so no line adds to the next.
        var items: [OrderedJSON.JSONValue] = []
        var skipped: [A2UIDiagnostic] = []
        var anyTooDeep = false
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0D]
        for (index, line) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated()
        where !line.allSatisfy(whitespace.contains) {
            switch decodeJSON(Data(line)) {
            case .value(let item):
                items.append(item)
            case .tooDeep:
                anyTooDeep = true
                skipped.append(A2UIDiagnostic(
                    reason: .parseFailed, path: "line \(index + 1)",
                    message: "This line is nested more than \(maximumJSONDepth) deep, deeper than any A2UI, so it's skipped."))
            case .notJSON:
                skipped.append(A2UIDiagnostic(
                    reason: .parseFailed, path: "line \(index + 1)", message: "This line isn't JSON, so it's skipped."))
            }
        }
        guard items.isEmpty else {
            diagnostics += skipped
            return items
        }
        // Nothing in it could be read: one diagnostic says why.
        if case .tooDeep = whole {
            diagnostics.append(A2UIDiagnostic(
                reason: .parseFailed,
                message: "This JSON is nested more than \(maximumJSONDepth) deep, deeper than any A2UI, so it isn't read."))
        } else if anyTooDeep {
            diagnostics += skipped
        } else {
            diagnostics.append(A2UIDiagnostic(reason: .parseFailed, message: "This isn't JSON, so there's nothing to import."))
        }
        return []
    }

    /// Whether `data` opens more than `limit` arrays and objects inside one another, counted in
    /// one pass over its bytes, outside strings, without decoding anything. A newline byte ends
    /// any string, since JSON can't hold one inside a string, so a stray quote can't hide the
    /// lines after it.
    private static func nests(_ data: Data, deeperThan limit: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if byte == 0x0A || byte == 0x0D {
                inString = false
                escaped = false
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > limit { return true }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth = max(depth - 1, 0)
            default:
                break
            }
        }
        return false
    }

    /// Whether a data-model path takes more steps than Layer follows. It looks at no more of the
    /// path than it needs to tell.
    fileprivate static func isTooLong(_ path: String) -> Bool {
        path.split(separator: "/", maxSplits: maximumPathSteps, omittingEmptySubsequences: true).count > maximumPathSteps
    }

    /// How many values writing `path` could add by growing lists: each step that is a list index
    /// (as the SDK reads one: digits, without a leading zero) can grow a list to it. Nil when a step
    /// reaches past `maximumPathIndex`. The path is no more than `maximumPathSteps` long.
    fileprivate static func listGrowth(of path: String) -> Int? {
        var growth = 0
        for step in path.split(separator: "/", omittingEmptySubsequences: true)
        where !step.isEmpty && step.allSatisfy({ $0.isASCII && $0.isNumber }) && !(step.count > 1 && step.hasPrefix("0")) {
            guard step.count <= 9, let index = Int(step), index <= maximumPathIndex else { return nil }
            growth += index + 1
        }
        return growth
    }

    /// How many values a JSON value holds, itself included. It walks with a list, not recursion.
    fileprivate static func count(_ value: OrderedJSON.JSONValue) -> Int {
        var total = 0
        var pending = [value]
        while let next = pending.popLast() {
            total += 1
            if let items = next.arrayValue { pending += items } else if let fields = next.objectValue { pending += fields.values }
        }
        return total
    }
}

// MARK: - Surfaces

/// A component as written: its properties by name, `id` and `component` among them.
private typealias Component = [String: OrderedJSON.JSONValue]

/// One surface as its messages leave it.
private struct Surface {
    let id: String
    var catalogID: String?
    var wasCreated = false
    /// By id: the last write of each wins.
    var components: [String: Component] = [:]
    /// The ids in the order they were first written, so diagnostics come in a steady order.
    var order: [String] = []
    /// Nil when no data model was sent.
    var dataModel: OrderedJSON.JSONValue?
    /// The screen's name and device, from `createSurface.metadata.extensions.layer`.
    var name: String?
    var deviceID: String?

    init(id: String) {
        self.id = id
    }

    /// Keeps each component by its id. Two with one id in one message are reported; the later wins.
    mutating func write(_ written: [Component], in action: String, into diagnostics: inout [A2UIDiagnostic]) {
        var ids: Set<String> = []
        for (index, component) in written.enumerated() {
            let place = "\(action).components[\(index)]"
            guard let id = component["id"]?.stringValue, !id.isEmpty else {
                diagnostics.append(A2UIDiagnostic(
                    reason: .invalidComponent, path: "\(place).id", message: "A component without an id can't be imported."))
                continue
            }
            if !ids.insert(id).inserted {
                diagnostics.append(A2UIDiagnostic(
                    reason: .duplicateID, componentID: id, path: place,
                    message: "Two components in one message have the id \(id), so the later one is used."))
            }
            if components[id] == nil { order.append(id) }
            components[id] = component
        }
    }
}

extension A2UIImporter {
    /// Each surface the messages leave, in the order each was first named.
    fileprivate static func gather(_ messages: [AgentToRendererMessage], into diagnostics: inout [A2UIDiagnostic]) -> [Surface] {
        // A deleted surface leaves a gap, so the others keep their places in `index`.
        var surfaces: [Surface?] = []
        var index: [String: Int] = [:]
        var valuesLeft = maximumDataModelValues

        /// The surface a message names. One no createSurface made first is made now, and reported.
        func surfaceIndex(_ id: String, for action: String) -> Int {
            if let found = index[id] { return found }
            diagnostics.append(A2UIDiagnostic(
                reason: .unresolved, path: "\(action).surfaceId",
                message: "Surface \(id) wasn't created before this \(action), so it's imported as it is."))
            return made(id)
        }

        func made(_ id: String) -> Int {
            surfaces.append(Surface(id: id))
            index[id] = surfaces.count - 1
            return surfaces.count - 1
        }

        /// Whether the data models have room for `values` more. Once one doesn't fit, nothing
        /// more is written, and that is said once.
        func fits(_ values: Int, at path: String) -> Bool {
            guard values > valuesLeft else {
                valuesLeft -= values
                return true
            }
            if valuesLeft >= 0 {
                diagnostics.append(A2UIDiagnostic(
                    reason: .binding, path: path,
                    message: "The data model passes \(maximumDataModelValues) values here, so this and what comes after it isn't written."))
            }
            valuesLeft = -1
            return false
        }

        for message in messages {
            switch message {
            case .createSurface(let create):
                let found: Int
                if let known = index[create.surfaceID] {
                    guard surfaces[known]?.wasCreated == false else {
                        diagnostics.append(A2UIDiagnostic(
                            reason: .duplicateID, path: "createSurface.surfaceId",
                            message: "Surface \(create.surfaceID) is created twice, so the second createSurface is ignored."))
                        continue
                    }
                    found = known
                } else {
                    found = made(create.surfaceID)
                }
                surfaces[found]?.wasCreated = true
                surfaces[found]?.catalogID = create.catalogID
                let layer = create.metadata?["extensions"]?.objectValue?["layer"]?.objectValue
                surfaces[found]?.name = layer?["name"]?.stringValue
                surfaces[found]?.deviceID = layer?["deviceID"]?.stringValue
                if let components = create.components {
                    surfaces[found]?.write(components, in: "createSurface", into: &diagnostics)
                }
                if let model = create.dataModel, fits(1 + model.values.map(count).reduce(0, +), at: "createSurface.dataModel") {
                    // As JSON, so it reads as `updateDataModel` leaves it.
                    if let encoded = try? JSONEncoder().encode(model), case .value(let value) = decodeJSON(encoded) {
                        surfaces[found]?.dataModel = value
                    }
                }
            case .updateComponents(let update):
                let found = surfaceIndex(update.surfaceID, for: "updateComponents")
                surfaces[found]?.write(update.components, in: "updateComponents", into: &diagnostics)
            case .updateDataModel(let update):
                let found = surfaceIndex(update.surfaceID, for: "updateDataModel")
                guard !isTooLong(update.path) else {
                    diagnostics.append(A2UIDiagnostic(
                        reason: .binding, path: "updateDataModel.path",
                        message: "Its path is more than \(maximumPathSteps) steps long, so this update is skipped."))
                    continue
                }
                guard let growth = listGrowth(of: update.path) else {
                    diagnostics.append(A2UIDiagnostic(
                        reason: .binding, path: "updateDataModel.path",
                        message: "Its path reaches past item \(maximumPathIndex) of a list, so this update is skipped."))
                    continue
                }
                guard fits(1 + growth + (update.value.map(count) ?? 0), at: "updateDataModel.value") else { continue }
                var model = surfaces[found]?.dataModel ?? [:]
                surfaces[found]?.dataModel = nil
                model[update.path] = update.value
                surfaces[found]?.dataModel = model
            case .deleteSurface(let delete):
                if let found = index.removeValue(forKey: delete.surfaceID) { surfaces[found] = nil }
            case .callRendererFunction(let call):
                diagnostics.append(A2UIDiagnostic(
                    reason: .functionNotRun, path: "callRendererFunction",
                    message: "Layer never runs functions, so \(call.callFunction.call) isn't called."))
            case .agentFunctionResponse:
                diagnostics.append(A2UIDiagnostic(
                    reason: .functionNotRun, path: "agentFunctionResponse",
                    message: "Layer never calls an agent's functions, so this answer is ignored."))
            }
        }
        return surfaces.compactMap { $0 }
    }
}

// MARK: - Building a screen

/// The spacings an import starts from, which A2UI doesn't give: steps of Layer's rhythm in the
/// standard tokens. A screen root's sections are 24 apart, as the outline spaces them; a section's
/// lines, and a grid's cells, 12; and what is in a card, a list, or a row of a mark and its label, 8.
private enum Rhythm {
    static let screen = DesignTokens.standard.rhythm[3]
    static let section = DesignTokens.standard.rhythm[1]
    static let tight = DesignTokens.standard.rhythm[0]
}

/// Where a component is built: how deep in the graph below root, under which components, in
/// which template item, and along which axis its parent stacks it.
private struct Place {
    var depth = 0
    var ancestors: [String] = []
    /// The data-model pointer of the template item being built; empty outside templates.
    var scope = ""
    /// Set only when the parent is a row or column, where a child's `weight` means something.
    var axis: LayerNode.Axis?

    /// Where a child of `id` is built.
    func inside(_ id: String, axis: LayerNode.Axis? = nil) -> Place {
        Place(depth: depth + 1, ancestors: ancestors + [id], scope: scope, axis: axis)
    }
}

/// A component waiting to be built, and where; `parent` and `field` say what holds it.
private struct Request {
    var id: String
    var parent: String?
    var field: String?
    var place: Place
}

/// A container being built: its node, and the requests for its children, `next` the first not yet made.
private struct OpenContainer {
    var node: LayerNode
    var id: String
    var component: Component
    var place: Place
    var requests: [Request]
    var next = 0
}

/// What starting a request makes.
private enum Start {
    case node(LayerNode)
    case container(OpenContainer)
    /// Another component stands in for it, as a modal's trigger does.
    case instead(Request)
    case nothing
}

/// Builds one surface's screen: walks its graph, checks the components it reaches, maps them to
/// nodes and fixes them.
private struct ScreenBuilder {
    /// What is left of the import's limits: the nodes it may still make, and the children it may
    /// still consider.
    struct Budget {
        var nodes: Int
        var childRequests: Int
        /// Whether running out of children to consider has been said, which is said once an import.
        var saidChildRequestsAreSpent = false
    }

    let surface: Surface
    private(set) var diagnostics: [A2UIDiagnostic] = []
    /// What the import has left once this screen is built.
    private(set) var budget: Budget

    /// The catalogue each component is read against, by id, found as the walk reaches it.
    private var catalogs: [String: AnyCatalog] = [:]
    /// The component each node was made from, by node, for the fixes' diagnostics.
    private var componentOfNode: [UUID: String] = [:]
    private var madeNodes = 0
    /// How many nodes so far have each key, so a key met again is numbered (see `make`).
    private var keysMade: [String: Int] = [:]
    /// Each diagnostic given so far, so a template's items don't repeat them.
    private var given: Set<String> = []

    private static let strict = ValidationConfig(protocolVersion: .v10)
    private static let basicCatalog = BasicCatalog.makeCatalog(version: .v10)
    private static let basicValidator = PayloadValidator(catalog: basicCatalog, config: strict)
    private static let layerValidator = PayloadValidator(catalog: LayerCatalog.catalog, config: strict)

    private static let containerTypes: Set<String> = ["Column", "Row", "List", "LayerGrid", "LayerOverlay", "LayerFree"]

    /// A caption's colour: iOS's secondary label as it shows on white.
    private static let secondaryText = RGBColor(hex: 0x8A8A8E)

    init(surface: Surface, budget: Budget) {
        self.surface = surface
        self.budget = budget
    }

    mutating func build() -> LayerNode? {
        guard let rootComponent = surface.components["root"] else {
            report(.missingRoot, nil, nil, "Surface \(surface.id) has no component with the id root, so it makes no screen.")
            return nil
        }
        let reached = walk()
        check(reached)
        guard let mapped = tree(from: "root") else { return nil }
        let rootType = rootComponent["component"]?.stringValue
        var root = screenRoot(mapped, isScreen: rootType == "Column" || rootType == "LayerFree")
        fix(&root)
        budget.nodes -= Self.count(root)
        return root
    }

    /// How many nodes a tree holds.
    private static func count(_ root: LayerNode) -> Int {
        var total = 0
        var pending = [root]
        while let node = pending.popLast() {
            total += 1
            pending += node.children
        }
        return total
    }

    private mutating func report(_ reason: A2UIDiagnostic.Reason, _ id: String?, _ path: String?, _ message: String) {
        guard given.insert(reason.rawValue + "|" + (id ?? "") + "|" + (path ?? "") + "|" + message).inserted else { return }
        diagnostics.append(A2UIDiagnostic(reason: reason, componentID: id, path: path, message: message))
    }

    // MARK: Catalogues and validation

    /// The catalogue a component is read against, found the first time it's asked for.
    private mutating func catalog(of id: String) -> AnyCatalog? {
        if let known = catalogs[id] { return known }
        guard let component = surface.components[id] else { return nil }
        let found = readsAsBasic(component, id: id) ? Self.basicCatalog : LayerCatalog.catalog
        catalogs[id] = found
        return found
    }

    /// Validates each component the walk reached against its catalogue, strictly. One nothing
    /// reaches isn't imported, so it isn't validated: it's only said to be unreachable.
    private mutating func check(_ reached: Set<String>) {
        for id in surface.order where reached.contains(id) {
            guard let component = surface.components[id], let catalog = catalog(of: id) else { continue }
            do {
                try (catalog.id == LayerCatalog.id ? Self.layerValidator : Self.basicValidator).validateComponent(component)
            } catch let error as A2UIValidationError {
                if error.details.contains(where: { $0.code == "unknown_component" }) {
                    let type = component["component"]?.stringValue ?? ""
                    report(.unknownComponent, id, "component", "Layer doesn't know the component \(type), so it and what it holds aren't imported.")
                } else if error.details.isEmpty {
                    report(.invalidComponent, id, nil, error.message)
                } else {
                    for detail in error.details { report(.invalidComponent, id, detail.path, detail.message) }
                }
            } catch {
                report(.invalidComponent, id, nil, error.localizedDescription)
            }
        }
    }

    /// Whether a component is read against the Basic Catalog rather than Layer's, which holds
    /// the Basic Catalog's components too. One naming no catalogue, or one Layer doesn't know,
    /// is reported and read with Layer's.
    private mutating func readsAsBasic(_ component: Component, id: String) -> Bool {
        let named = component["@catalogId"]?.stringValue ?? surface.catalogID
        if named == LayerCatalog.basicID { return true }
        if named == LayerCatalog.id { return false }
        if let named {
            report(.noCatalog, id, nil, "Layer doesn't know the catalogue \(named), so it's read with Layer's own.")
        } else {
            report(.noCatalog, id, nil, "Neither it nor its surface names a catalogue, so it's read with Layer's own.")
        }
        return false
    }

    // MARK: The graph

    /// Walks every child slot from root, each component once, and reports each reference to a
    /// component that isn't there, each one back to an ancestor, and each component nothing
    /// reaches. Returns the components it reached.
    private mutating func walk() -> Set<String> {
        var open: Set<String> = ["root"]
        var done: Set<String> = []
        var stack: [(id: String, references: [GraphTopologyValidator.Reference], next: Int)] = [("root", references(of: "root"), 0)]
        while let top = stack.last {
            guard top.next < top.references.count else {
                open.remove(top.id)
                done.insert(top.id)
                stack.removeLast()
                continue
            }
            stack[stack.count - 1].next += 1
            let reference = top.references[top.next]
            let target = reference.referenceID
            if surface.components[target] == nil {
                report(.unresolved, top.id, reference.field, "It holds \(target), which isn't there, so that's left out.")
            } else if open.contains(target) {
                reportCycle(from: top.id, field: reference.field, to: target)
            } else if !done.contains(target) {
                open.insert(target)
                stack.append((target, references(of: target), 0))
            }
        }
        for id in surface.order where !done.contains(id) {
            report(.unreachable, id, nil, "Nothing reaches it from root, so it isn't imported.")
        }
        return done
    }

    /// The ids a component holds in its child slots, in a steady order.
    private mutating func references(of id: String) -> [GraphTopologyValidator.Reference] {
        guard let component = surface.components[id] else { return [] }
        let found: [GraphTopologyValidator.Reference]
        if let type = component["component"]?.stringValue, let schema = catalog(of: id)?.components[type]?.schema.jsonValue {
            found = GraphTopologyValidator.extractReferences(from: component, schema: schema)
        } else {
            // Unknown, so there's no schema to say where its children are: the Basic Catalog's names.
            var plain: [GraphTopologyValidator.Reference] = []
            if let child = component["child"]?.stringValue { plain.append((child, "child")) }
            for (index, item) in (component["children"]?.arrayValue ?? []).enumerated() {
                if let child = item.stringValue { plain.append((child, "children[\(index)]")) }
            }
            if let template = component["children"]?.objectValue?["componentId"]?.stringValue {
                plain.append((template, "children.componentId"))
            }
            found = plain
        }
        // A component's properties come in no steady order, but the references in each come in
        // the order they're written: so by property, and in each as written.
        let properties: [Substring] = found.map { reference in reference.field.prefix { $0 != "[" && $0 != "." } }
        let order = found.indices.sorted { a, b in
            properties[a] != properties[b] ? properties[a] < properties[b] : a < b
        }
        return order.map { found[$0] }
    }

    private mutating func reportCycle(from id: String, field: String, to ancestor: String) {
        report(.cycle, id, field, "It holds \(ancestor), which already holds it, so that reference is cut.")
    }

    // MARK: Mapping

    /// The component `id`, if it can be built at `place`: it's there, it isn't one of its own
    /// ancestors, it's no more than 50 below root, its catalogue knows it, and the import's node
    /// limit isn't passed. Each reason it can't is reported once, here or in the walk or the check.
    private mutating func admit(_ id: String, from parent: String?, field: String?, at place: Place) -> Component? {
        guard let component = surface.components[id] else { return nil }
        if place.ancestors.contains(id) {
            if let parent, let field { reportCycle(from: parent, field: field, to: id) }
            return nil
        }
        guard place.depth <= A2UIImporter.maximumGraphDepth else {
            report(.tooDeep, id, nil, "It's more than \(A2UIImporter.maximumGraphDepth) levels below root, so it and what it holds aren't imported.")
            return nil
        }
        guard let type = component["component"]?.stringValue, catalogs[id]?.components[type] != nil else { return nil }
        // One past the limit is made, so the fixes cut it and say so.
        guard madeNodes <= budget.nodes else { return nil }
        return component
    }

    /// How many of the `count` children component `id` asks for the import may still consider.
    /// Once it may consider no more, that's said once, and nothing more is asked for.
    private mutating func considered(_ count: Int, by id: String) -> Int {
        let allowed = min(count, max(0, budget.childRequests))
        budget.childRequests -= allowed
        if allowed < count, !budget.saidChildRequestsAreSpent {
            budget.saidChildRequestsAreSpent = true
            report(.invalidComponent, id, "children",
                   "The import asks for more than \(A2UIImporter.maximumChildRequests) children in all, so from here on what it holds isn't imported.")
        }
        return allowed
    }

    /// The tree from component `id` down. It's built with a stack of open containers rather than
    /// by recursion, so no graph, however deep, and no build of the app can run out of stack.
    private mutating func tree(from id: String) -> LayerNode? {
        var open: [OpenContainer] = []
        var built: LayerNode?
        var next: Request? = Request(id: id, place: Place())
        while next != nil || !open.isEmpty {
            if let request = next {
                next = nil
                switch start(request) {
                case .node(let node):
                    if open.isEmpty { built = node } else { open[open.count - 1].node.children.append(node) }
                case .container(let container):
                    open.append(container)
                case .instead(let other):
                    next = other
                case .nothing:
                    break
                }
            } else if open[open.count - 1].next < open[open.count - 1].requests.count {
                next = open[open.count - 1].requests[open[open.count - 1].next]
                open[open.count - 1].next += 1
            } else {
                var done = open.removeLast()
                finish(&done.node, done.id, done.component, at: done.place)
                if open.isEmpty { built = done.node } else { open[open.count - 1].node.children.append(done.node) }
            }
        }
        return built
    }

    /// What one request makes: a finished leaf, a container whose children are still to come,
    /// another component that stands in for it, or nothing.
    private mutating func start(_ request: Request) -> Start {
        let id = request.id, place = request.place
        guard let component = admit(id, from: request.parent, field: request.field, at: place) else { return .nothing }
        let type = component["component"]?.stringValue ?? ""
        switch type {
        case _ where Self.containerTypes.contains(type):
            var node = make(.group, id, at: place)
            // A screen's root column is spaced as the outline spaces one, and a column in it as a section.
            node.layout = layout(of: id, component, spacing: place.depth == 0 && type == "Column" ? Rhythm.screen : Rhythm.section)
            let requests = childRequests(of: id, component, at: place.inside(id, axis: node.layout?.stackAxis))
            return .container(OpenContainer(node: node, id: id, component: component, place: place, requests: requests))
        case "Card":
            return .container(card(id, component, at: place))
        case "Tabs":
            report(.nearestKind, id, "tabs", "Layer has no tabs, so only the first tab's content is imported.")
            guard let first = component["tabs"]?.arrayValue?.first?.objectValue?["child"]?.stringValue else { return .nothing }
            return .instead(Request(id: first, parent: id, field: "tabs[0].child", place: place.inside(id, axis: place.axis)))
        case "Modal":
            report(.nearestKind, id, "content", "Layer has no modal sheets, so only what opens this one is imported.")
            guard let trigger = component["trigger"]?.stringValue else { return .nothing }
            return .instead(Request(id: trigger, parent: id, field: "trigger", place: place.inside(id, axis: place.axis)))
        default:
            guard var node = leaf(id, component, type: type, at: place) else { return .nothing }
            finish(&node, id, component, at: place)
            return .node(node)
        }
    }

    /// The node for a component that holds no others in Layer: everything but containers,
    /// cards, tabs and modals. Nil for a type nothing here maps.
    private mutating func leaf(_ id: String, _ component: Component, type: String, at place: Place) -> LayerNode? {
        var node: LayerNode
        switch type {
        case "Text":
            node = text(id, component, at: place)
        case "Image":
            let variant = component["variant"]?.stringValue
            node = make(variant == "avatar" ? .avatar : variant == "icon" ? .symbol : .image, id, at: place)
            if node.kind == .symbol { node.content.symbol = "photo" }
            node.name = Self.nonEmpty(string(component["description"], of: id, field: "description", at: place))
        case "Icon":
            node = make(.symbol, id, at: place)
            node.content.symbol = iconSymbol(component, id: id, at: place)
        case "Video", "AudioPlayer":
            node = make(.image, id, at: place)
            node.name = Self.nonEmpty(string(component["description"], of: id, field: "description", at: place))
            report(.nearestKind, id, nil, "Layer can't play \(type == "Video" ? "video" : "sound"), so it's an image placeholder.")
        case "Divider":
            node = make(.divider, id, at: place)
            if component["axis"]?.stringValue == "vertical" {
                report(.nearestKind, id, "axis", "Layer's dividers run across, so this vertical one does too.")
            }
        case "Button":
            node = button(id, component, at: place)
        case "TextField":
            node = make(.textField, id, at: place)
            let label = Self.nonEmpty(string(component["label"], of: id, field: "label", at: place))
            node.content.text = label
                ?? Self.nonEmpty(string(component["placeholder"], of: id, field: "placeholder", at: place))
                ?? ElementKind.textField.placeholder
        case "CheckBox":
            node = checkBox(id, component, at: place)
        case "ChoicePicker":
            node = choicePicker(id, component, at: place)
        case "Slider":
            node = make(.progress, id, at: place)
            let low = component["min"]?.doubleValue ?? 0, high = component["max"]?.doubleValue ?? 1
            if let value = number(component["value"], of: id, field: "value", at: place), high > low {
                let fraction = (value - low) / (high - low)
                if fraction.isFinite { node.content.value = min(max(fraction, 0), 1) }
            }
            report(.nearestKind, id, nil, "Layer has no slider, so it's a progress bar.")
        case "DateTimeInput":
            node = make(.textField, id, at: place)
            node.content.text = Self.nonEmpty(string(component["label"], of: id, field: "label", at: place))
                ?? ElementKind.textField.placeholder
            report(.nearestKind, id, nil, "Layer has no date or time picker, so it's a text field.")
        case "LayerToggle", "LayerRadio":
            node = make(type == "LayerToggle" ? .toggle : .radio, id, at: place)
            if let isOn = bool(component["value"], of: id, field: "value", at: place) { node.content.isOn = isOn }
            node.name = Self.nonEmpty(string(component["label"], of: id, field: "label", at: place))
        case "LayerProgress":
            node = make(.progress, id, at: place)
            if let value = component["value"]?.doubleValue, value.isFinite { node.content.value = min(max(value, 0), 1) }
        case "LayerSymbol":
            node = make(.symbol, id, at: place)
            node.content.symbol = component["name"]?.stringValue
        case "LayerShape":
            node = make(.shape, id, at: place)
            node.content.shape = component["shape"]?.stringValue.flatMap(ShapeKind.init(rawValue:))
            if let filled = component["filled"]?.boolValue { node.content.isOn = filled }
        default:
            // Known to its catalogue but to nothing above: no such component today.
            report(.unknownComponent, id, "component", "Layer has no node for the component \(type), so it isn't imported.")
            return nil
        }
        return node
    }

    /// A new node of `kind` made from component `id`, at its kind's starting size, keyed so that
    /// every node's key is its own and the same file always gives the same keys: the id, with
    /// `/` and `part` for a further node made from the same component, and `@` and the item's
    /// pointer inside a template. The id is escaped (`~0` `~`, `~1` `/`, `~2` `@`, `~3` `#`), and
    /// the pointer too but for its slashes, so none of those marks can come from either. A key
    /// already made, as for a component two parents share, is numbered from the second time on
    /// in reading order: `line`, `line#2`, `line#3`.
    private mutating func make(_ kind: ElementKind, _ id: String, part: String? = nil, at place: Place) -> LayerNode {
        var node = LayerNode(kind: kind)
        (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
        var key = Self.escaped(id, keepingSlashes: false)
        if let part { key += "/" + part }
        if !place.scope.isEmpty { key += "@" + Self.escaped(place.scope, keepingSlashes: true) }
        let made = keysMade[key, default: 0] + 1
        keysMade[key] = made
        if made > 1 { key += "#\(made)" }
        node.source = LayerNode.Source(origin: .imported, key: key)
        componentOfNode[node.id] = id
        madeNodes += 1
        return node
    }

    /// What every component's node gets last: its kind's starting size if Layer's look names
    /// another kind, its weight in a row or column, its accessibility label, then Layer's look.
    private mutating func finish(_ node: inout LayerNode, _ id: String, _ component: Component, at place: Place) {
        let look = self.look(of: id, component)
        if let kind = look.kind, kind != node.kind {
            node.kind = kind
            (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
            if !node.isContainer {
                node.layout = nil
                node.padding = LayerNode.Padding()
            }
        }
        if let axis = place.axis, let weight = component["weight"]?.doubleValue, weight > 0 {
            let fill = LayerNode.Sizing(.fill(weight: CGFloat(weight)))
            if axis == .horizontal { node.width = fill } else { node.height = fill }
        }
        if let label = component["@accessibility"]?.objectValue?["label"],
           let words = Self.nonEmpty(string(label, of: id, field: "@accessibility.label", at: place)) {
            node.accessibility = LayerNode.Accessibility(label: words)
        }
        look.apply(to: &node)
    }

    /// `text` with the marks a key is built with escaped, as a JSON pointer escapes `~` and `/`.
    private static func escaped(_ text: String, keepingSlashes: Bool) -> String {
        var escaped = text.replacingOccurrences(of: "~", with: "~0")
        if !keepingSlashes { escaped = escaped.replacingOccurrences(of: "/", with: "~1") }
        return escaped.replacingOccurrences(of: "@", with: "~2").replacingOccurrences(of: "#", with: "~3")
    }

    /// How a row, column, list, grid, overlay or free group lays out its children. A2UI gives
    /// a row or column no spacing, so it gets `spacing`, from Layer's rhythm.
    private mutating func layout(of id: String, _ component: Component, spacing: CGFloat) -> LayerNode.Layout {
        switch component["component"]?.stringValue {
        case "LayerGrid":
            return .grid(LayerNode.Grid(
                columns: component["columns"]?.intValue ?? 2,
                columnSpacing: component["columnSpacing"]?.doubleValue.map { CGFloat($0) } ?? Rhythm.section,
                rowSpacing: component["rowSpacing"]?.doubleValue.map { CGFloat($0) } ?? Rhythm.section,
                alignment: LayerNode.Alignment(horizontal: .start, vertical: .start)))
        case "LayerOverlay":
            return .overlay(LayerNode.Alignment(
                horizontal: component["horizontal"]?.stringValue.flatMap(LayerNode.Edge3.init(rawValue:)) ?? .center,
                vertical: component["vertical"]?.stringValue.flatMap(LayerNode.Edge3.init(rawValue:)) ?? .center))
        case "LayerFree":
            return .free
        case let type:
            let isRow = type == "Row" || (type == "List" && component["direction"]?.stringValue == "horizontal")
            if type == "List" {
                report(.nearestKind, id, nil, "A list scrolls in an app; here it's a \(isRow ? "row" : "column") that doesn't.")
            }
            let alignment: LayerNode.CrossAlignment
            switch component["align"]?.stringValue {
            case "start": alignment = .start
            case "center": alignment = .center
            case "end": alignment = .end
            default: alignment = .fill
            }
            let justify: LayerNode.Justify
            switch component["justify"]?.stringValue {
            case "center": justify = .center
            case "end": justify = .end
            case "spaceBetween": justify = .spaceBetween
            case "spaceAround": justify = .spaceAround
            case "spaceEvenly": justify = .spaceEvenly
            case "stretch":
                justify = .start
                report(.nearestKind, id, "justify", "Layer doesn't stretch children along a row or column, so they start at its start.")
            default: justify = .start
            }
            return .stack(LayerNode.Stack(axis: isRow ? .horizontal : .vertical, spacing: spacing, alignment: alignment, justify: justify))
        }
    }

    /// What a container's `children` ask for: its list of ids, or its template once for each
    /// item of the data model's list.
    private mutating func childRequests(of id: String, _ component: Component, at place: Place) -> [Request] {
        if let template = component["children"]?.objectValue {
            return repeated(template["componentId"]?.stringValue, over: template["path"]?.stringValue, of: id, at: place)
        }
        let children = component["children"]?.arrayValue ?? []
        return children.prefix(considered(children.count, by: id)).enumerated().compactMap { index, item in
            item.stringValue.map { Request(id: $0, parent: id, field: "children[\(index)]", place: place) }
        }
    }

    /// A template's component once for each item of the data-model list at `path`, each reading
    /// relative paths inside its item. Without that list it's built once, and reported.
    private mutating func repeated(_ item: String?, over path: String?, of id: String, at place: Place) -> [Request] {
        guard let item, let path else { return [] }
        let pointer = Self.pointer(path, in: place.scope)
        let count: Int
        if A2UIImporter.isTooLong(pointer) {
            report(.template, id, "children", "Its children repeat over a path more than \(A2UIImporter.maximumPathSteps) steps long, so one is shown.")
            count = 1
        } else if let list = surface.dataModel?[pointer]?.arrayValue {
            // Each item makes a node at least, so no more are asked for than can be kept.
            count = min(list.count, max(0, budget.nodes) + 1)
        } else {
            let why = surface.dataModel == nil ? "no data model was sent" : "the data model has no list there"
            report(.template, id, "children", "Its children repeat over \(path), but \(why), so one is shown.")
            count = 1
        }
        return (0..<considered(count, by: id)).map { index in
            var each = place
            each.scope = "\(pointer)/\(index)"
            return Request(id: item, parent: id, field: "children.componentId", place: each)
        }
    }

    /// A card, with a card's padding. A card holding a row, column, list, grid, overlay or free
    /// group becomes that container as a card: one node with its layout and its children. A card
    /// holding anything else stacks it.
    private mutating func card(_ id: String, _ component: Component, at place: Place) -> OpenContainer {
        var card = make(.card, id, at: place)
        card.padding = LayerNode.Padding(all: DesignTokens.standard.card.padding)
        card.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: Rhythm.tight))
        var requests: [Request] = []
        let inside = place.inside(id)
        if let childID = component["child"]?.stringValue, let child = admit(childID, from: id, field: "child", at: inside) {
            if let type = child["component"]?.stringValue, Self.containerTypes.contains(type) {
                card.layout = look(of: childID, child).layout ?? layout(of: childID, child, spacing: Rhythm.tight)
                requests = childRequests(of: childID, child, at: inside.inside(childID, axis: card.layout?.stackAxis))
            } else {
                requests = [Request(id: childID, parent: id, field: "child", place: inside)]
            }
        }
        return OpenContainer(node: card, id: id, component: component, place: place, requests: requests)
    }

    /// A title when its Markdown is a `#` or `##` heading, body when it runs past one line,
    /// else text; a caption in the secondary text colour. Markdown's markers are taken out.
    private mutating func text(_ id: String, _ component: Component, at place: Place) -> LayerNode {
        let written = string(component["text"], of: id, field: "text", at: place).map(Markdown.init)
        let kind: ElementKind
        if written?.isHeading == true {
            kind = .title
        } else if written?.words.contains(where: \.isNewline) == true {
            kind = .body
        } else {
            kind = .text
        }
        var node = make(kind, id, at: place)
        node.content.text = written?.words ?? kind.placeholder
        if component["variant"]?.stringValue == "caption" { node.style.textColor = Self.secondaryText }
        return node
    }

    /// A button: filled, bordered or plain for primary, default and borderless, saying its
    /// child's text. A button showing only an icon is that icon's symbol.
    private mutating func button(_ id: String, _ component: Component, at place: Place) -> LayerNode {
        if let action = component["action"],
           action.objectValue?["event"]?.objectValue?["name"]?.stringValue != A2UIImporter.layerActionName {
            report(.actionNotRun, id, "action", "Its action isn't run in Layer.")
        }
        let inside = place.inside(id)
        let childID = component["child"]?.stringValue
        var child: Component?
        if let childID { child = admit(childID, from: id, field: "child", at: inside) }
        if let childID, let child, child["component"]?.stringValue == "Icon" {
            report(.nearestKind, id, "child", "Layer's buttons show words, so a button showing only an icon is the icon.")
            var symbol = make(.symbol, id, at: place)
            symbol.content.symbol = iconSymbol(child, id: childID, at: inside)
            return symbol
        }
        var button = make(.button, id, at: place)
        switch component["variant"]?.stringValue {
        case "primary": button.content.buttonLook = .filled
        case "borderless": button.content.buttonLook = .plain
        default: button.content.buttonLook = .bordered
        }
        button.content.text = words(of: childID, child, in: id, at: inside) ?? ElementKind.button.placeholder
        return button
    }

    /// What a button says: its child's text, or else the first text inside its child.
    private mutating func words(of childID: String?, _ child: Component?, in id: String, at place: Place) -> String? {
        guard let childID, let child else { return nil }
        if child["component"]?.stringValue == "Text" {
            return string(child["text"], of: childID, field: "text", at: place).map { Markdown($0).words }
        }
        report(.nearestKind, id, "child", "Layer's buttons show words only, so only the first text inside it is kept.")
        // Breadth first through what the child holds, each component once, looking at no more than 100.
        var queue = [childID]
        var seen: Set<String> = [childID]
        var next = 0
        while next < queue.count, next < 100 {
            let current = queue[next]
            next += 1
            guard let component = surface.components[current] else { continue }
            if component["component"]?.stringValue == "Text" {
                return string(component["text"], of: current, field: "text", at: place).map { Markdown($0).words }
            }
            for reference in references(of: current) where seen.insert(reference.referenceID).inserted {
                queue.append(reference.referenceID)
            }
        }
        return nil
    }

    /// The SF Symbol for an Icon's `name`, one of the catalogue's names or one bound to the data
    /// model. An SVG path can't be drawn, so it's the placeholder.
    private mutating func iconSymbol(_ component: Component, id: String, at place: Place) -> String {
        if component["name"]?.objectValue?["svgPath"] != nil {
            report(.nearestKind, id, "name", "Layer draws SF Symbols, not SVG paths, so this icon is a placeholder.")
            return SystemSymbol.placeholder
        }
        return string(component["name"], of: id, field: "name", at: place).map(A2UIIcons.symbol(for:)) ?? SystemSymbol.placeholder
    }

    /// A checkbox and its label, as a row. Layer's own checkbox, which its export writes as a
    /// CheckBox, comes back as the single node its look names.
    private mutating func checkBox(_ id: String, _ component: Component, at place: Place) -> LayerNode {
        let isOn = bool(component["value"], of: id, field: "value", at: place) ?? false
        if let kind = look(of: id, component).kind, kind != .group, kind != .card {
            var node = make(kind, id, at: place)
            node.content.isOn = isOn
            return node
        }
        var row = make(.group, id, at: place)
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: Rhythm.tight, alignment: .center))
        var box = make(.checkbox, id, part: "box", at: place)
        box.content.isOn = isOn
        var label = make(.text, id, part: "label", at: place)
        label.content.text = string(component["label"], of: id, field: "label", at: place) ?? ElementKind.text.placeholder
        row.children = [box, label]
        return row
    }

    /// A column of radio buttons, or of checkboxes when several can be chosen, each in a row
    /// with its label; the picker's own label above them.
    private mutating func choicePicker(_ id: String, _ component: Component, at place: Place) -> LayerNode {
        let mark: ElementKind = component["variant"]?.stringValue == "multipleSelection" ? .checkbox : .radio
        let chosen = Set(strings(component["value"], of: id, field: "value", at: place) ?? [])
        var column = make(.group, id, at: place)
        column.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: Rhythm.tight))
        if let label = Self.nonEmpty(string(component["label"], of: id, field: "label", at: place)) {
            var text = make(.text, id, part: "label", at: place)
            text.content.text = label
            column.children.append(text)
        }
        for (index, option) in (component["options"]?.arrayValue ?? []).enumerated() {
            guard madeNodes <= budget.nodes else { break }
            var row = make(.group, id, part: "\(index)", at: place)
            row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: Rhythm.tight, alignment: .center))
            var box = make(mark, id, part: "\(index)/mark", at: place)
            box.content.isOn = option.objectValue?["value"]?.stringValue.map { chosen.contains($0) } ?? false
            var text = make(.text, id, part: "\(index)/label", at: place)
            text.content.text = string(option.objectValue?["label"], of: id, field: "options[\(index)].label", at: place)
                ?? ElementKind.text.placeholder
            row.children = [box, text]
            column.children.append(row)
        }
        return column
    }

    // MARK: Values

    /// A dynamic value as it stands: a literal as written, or a binding read from the data model.
    /// Nil for a binding the data model can't answer and for a function call, which is never
    /// run; each is reported.
    private mutating func value(_ written: OrderedJSON.JSONValue?, of id: String, field: String, at place: Place) -> OrderedJSON.JSONValue? {
        guard let written, let fields = written.objectValue else { return written }
        if let path = fields["@path"]?.stringValue {
            let pointer = Self.pointer(path, in: place.scope)
            guard !A2UIImporter.isTooLong(pointer) else {
                report(.binding, id, field, "It reads a path more than \(A2UIImporter.maximumPathSteps) steps long, so a placeholder stands in.")
                return nil
            }
            guard let model = surface.dataModel else {
                report(.binding, id, field, "It reads \(path) from a data model that wasn't sent, so a placeholder stands in.")
                return nil
            }
            guard let found = model[pointer], found != .null else {
                report(.binding, id, field, "It reads \(path), which the data model doesn't have, so a placeholder stands in.")
                return nil
            }
            return found
        }
        if let call = fields["@call"]?.stringValue {
            report(.functionNotRun, id, field, "Its value comes from \(call), which Layer never runs, so a placeholder stands in.")
            return nil
        }
        return written
    }

    private mutating func string(_ written: OrderedJSON.JSONValue?, of id: String, field: String, at place: Place) -> String? {
        switch value(written, of: id, field: field, at: place) {
        case .string(let text)?:
            return text
        case .integer(let number)?:
            return String(number)
        case .number(let number)?:
            return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .boolean(let flag)?:
            return String(flag)
        case nil:
            return nil
        case .some:
            report(.binding, id, field, "Its value isn't text, so a placeholder stands in.")
            return nil
        }
    }

    private mutating func number(_ written: OrderedJSON.JSONValue?, of id: String, field: String, at place: Place) -> Double? {
        let found = value(written, of: id, field: field, at: place)
        return found?.doubleValue ?? found?.stringValue.flatMap { Double($0) }
    }

    private mutating func bool(_ written: OrderedJSON.JSONValue?, of id: String, field: String, at place: Place) -> Bool? {
        value(written, of: id, field: field, at: place)?.boolValue
    }

    private mutating func strings(_ written: OrderedJSON.JSONValue?, of id: String, field: String, at place: Place) -> [String]? {
        let found = value(written, of: id, field: field, at: place)
        return found?.arrayValue?.compactMap(\.stringValue) ?? found?.stringValue.map { [$0] }
    }

    /// A data-model path as a pointer from the model's root: a relative path reads inside the template item.
    private static func pointer(_ path: String, in scope: String) -> String {
        path.hasPrefix("/") ? path : "\(scope)/\(path)"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text?.isEmpty == false ? text : nil
    }

    // MARK: Layer's look

    /// Layer's own look from a component's `@metadata.extensions.layer`. Each key that can't be
    /// read is reported and left out; the rest still apply.
    private mutating func look(of id: String, _ component: Component) -> LayerLook {
        guard let written = component["@metadata"]?.objectValue?["extensions"]?.objectValue?["layer"] else { return LayerLook() }
        guard let fields = written.objectValue else {
            report(.invalidComponent, id, "@metadata.extensions.layer", "Layer's look here isn't an object, so it's ignored.")
            return LayerLook()
        }
        var look = LayerLook()
        func read<Value: Decodable>(_ key: String, as type: Value.Type) -> Value? {
            guard let raw = fields[key] else { return nil }
            if let value = LayerLook.decode(type, from: raw) { return value }
            report(.invalidComponent, id, "@metadata.extensions.layer.\(key)", "Layer's \(key) here can't be read, so it's left as imported.")
            return nil
        }
        look.kind = read("kind", as: ElementKind.self)
        look.frame = read("frame", as: LayerLook.Frame.self)?.rect
        look.rotation = read("rotation", as: Double.self)
        look.width = read("width", as: LayerNode.Sizing.self)
        look.height = read("height", as: LayerNode.Sizing.self)
        look.style = read("style", as: LayerNode.Style.self)
        look.content = read("content", as: LayerLook.ContentFields.self)?.content
        look.name = read("name", as: String.self)
        look.padding = read("padding", as: LayerNode.Padding.self)
        look.layout = read("layout", as: LayerNode.Layout.self)
        return look
    }

    // MARK: The screen root and the fixes

    /// A root Column is the screen root, as is a root LayerFree, which is how Layer writes a free
    /// screen, its children placed by their frames in Layer's look. Anything else is held in a
    /// column that is the screen root, spaced 24 as the outline spaces one. Either way it's a
    /// group with no padding: TreeRules writes a screen root's padding.
    private func screenRoot(_ mapped: LayerNode, isScreen: Bool) -> LayerNode {
        var root = mapped
        if !isScreen {
            root = LayerNode(kind: .group)
            (root.width, root.height) = NaturalSize.defaultSizing(for: .group)
            root.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: Rhythm.screen, alignment: .fill))
            root.source = LayerNode.Source(origin: .imported, key: nil)
            root.children = [mapped]
        }
        root.kind = .group
        root.padding = LayerNode.Padding()
        return root
    }

    /// Fixes the tree as generated trees are fixed, keeping it to the nodes the import has left,
    /// and reports each fix against its component.
    private mutating func fix(_ root: inout LayerNode) {
        for issue in TreeValidator.fixGenerated(&root, keepingAtMost: budget.nodes) {
            let id = issue.node.flatMap { componentOfNode[$0] }
            switch issue.kind {
            case .tooDeep:
                report(.tooDeep, id, nil, "It's at the deepest level a design can have, \(TreeRules.maximumDepth), so what it holds is moved up beside it.")
            case .tooMany:
                report(.invalidComponent, id, nil, "The import passes \(TreeRules.maximumNodes) nodes here, so this one and the rest aren't imported.")
            case .notAllowedHere:
                report(.invalidComponent, id, nil, "It can't be where it is, so it isn't imported.")
            case .badGeometry:
                report(.invalidComponent, id, nil, "A number in it that a design can't hold (not a number, negative where a size is meant, or far too large) is brought into range.")
            case .smallText:
                report(.nearestKind, id, nil, "Its text is raised to 11 points, the smallest Layer uses.")
            case .smallControl:
                report(.nearestKind, id, nil, "It's raised to 44 points high, the least a control can be.")
            case .clipped:
                report(.nearestKind, id, nil, "It goes past its screen.")
            }
        }
    }
}

// MARK: - Layer's look

/// Layer's own look for a node, from a component's `@metadata.extensions.layer`. Each key has the
/// shape `LayerNode` is saved in (`LayerNode+Coding.swift`), so Layer's export can write the
/// same; each one present wins over what the component maps to.
private struct LayerLook {
    var kind: ElementKind?
    var frame: CGRect?
    var rotation: Double?
    var width: LayerNode.Sizing?
    var height: LayerNode.Sizing?
    var style: LayerNode.Style?
    var content: LayerNode.Content?
    var name: String?
    var padding: LayerNode.Padding?
    var layout: LayerNode.Layout?

    /// Everything but the kind, which is given first, since it decides the starting size.
    func apply(to node: inout LayerNode) {
        if let width { node.width = width }
        if let height { node.height = height }
        if let frame { node.frame = frame }
        if let rotation { node.rotation = rotation }
        if let style { node.style = style }
        if let content { node.content = content }
        if let name { node.name = name }
        if let padding { node.padding = padding }
        if let layout { node.layout = layout }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from json: OrderedJSON.JSONValue) -> Value? {
        guard let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// `[x, y, width, height]`. `[[x, y], [width, height]]`, as a design saves a frame, is read too.
    struct Frame: Decodable {
        var rect: CGRect

        init(from decoder: any Decoder) throws {
            if let numbers = try? [CGFloat](from: decoder), numbers.count == 4 {
                rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            } else {
                rect = try CGRect(from: decoder)
            }
        }
    }

    /// A node's content under the keys, and with the defaults, a design saves it with.
    struct ContentFields: Decodable {
        var text: String?
        var symbol: String?
        var shape: ShapeKind?
        var imageID: UUID?
        var isOn: Bool?
        var value: Double?
        var buttonLook: ButtonLook?

        var content: LayerNode.Content {
            var content = LayerNode.Content()
            content.text = text ?? ""
            content.symbol = symbol
            content.shape = shape
            content.imageID = imageID
            content.isOn = isOn ?? true
            content.value = value
            content.buttonLook = buttonLook
            return content
        }
    }
}

/// Text as A2UI writes it, in a subset of Markdown: its words with the markers taken out.
private struct Markdown {
    var words: String
    /// A `#` or `##` heading on one line.
    var isHeading: Bool

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isHeading = !trimmed.contains(where: \.isNewline) && (trimmed.hasPrefix("# ") || trimmed.hasPrefix("## "))
        words = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { Self.plain(String($0)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line without its heading or quote marker, emphasis, code marks or link addresses.
    private static func plain(_ line: String) -> String {
        line.replacing(#/^\s{0,3}#{1,6}\s+/#, with: "")
            .replacing(#/^\s{0,3}>\s?/#, with: "")
            .replacing(#/\[([^\]]*)\]\([^)]*\)/#) { $0.output.1 }
            .replacing(#/\*\*|__|~~|`/#, with: "")
            .replacing(#/\*(\S[^*]*?)\*/#) { $0.output.1 }
            // An underscore inside a word, as in snake_case, isn't emphasis.
            .replacing(#/(^|[^\p{L}\p{N}_])_(\S[^_]*?)_(?=$|[^\p{L}\p{N}_])/#) { $0.output.1 + $0.output.2 }
    }
}

private extension LayerNode.Layout {
    /// The axis of a row or column; nil for grids, overlays and free groups.
    var stackAxis: LayerNode.Axis? {
        if case .stack(let stack) = self { return stack.axis }
        return nil
    }
}
