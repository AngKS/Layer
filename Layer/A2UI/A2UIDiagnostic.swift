/// Something an A2UI import couldn't bring in as it was written, and why. Imports never fail
/// on one bad part: each problem becomes one of these and the rest still comes in.
struct A2UIDiagnostic: Equatable, Sendable {
    enum Reason: String, CaseIterable, Sendable {
        /// A message isn't A2UI 1.0: no `version`, or another one.
        case notVersion1
        /// A message, or the whole file, can't be read as A2UI.
        case parseFailed
        /// Two components share an id in one message, or a surface is created twice.
        case duplicateID
        /// A component's catalogue is named nowhere, or isn't one Layer knows.
        case noCatalog
        /// A component breaks its schema, or can't be placed in the tree as written.
        case invalidComponent
        /// A component's type isn't in its catalogue.
        case unknownComponent
        /// A surface has no component with the id `root`, so it makes no screen.
        case missingRoot
        /// A component holds one of its own ancestors; that reference is cut.
        case cycle
        /// A reference to a component, or a surface, that isn't there.
        case unresolved
        /// A component nothing reaches from `root`.
        case unreachable
        /// The graph goes deeper than 50, or the tree deeper than 32.
        case tooDeep
        /// A value bound to the data model that the data model can't give.
        case binding
        /// Children repeated over the data model that the data model can't give.
        case template
        /// A button's action, which Layer never runs.
        case actionNotRun
        /// A function call, which Layer never runs.
        case functionNotRun
        /// Layer has no exact match, so the nearest thing it has stands in.
        case nearestKind
    }

    var reason: Reason
    var componentID: String?
    /// Where in the component or message, such as `children[1]` or `action`.
    var path: String?
    var message: String
}
