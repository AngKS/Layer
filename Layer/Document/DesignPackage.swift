/// The names of the parts of a design's package on disk. In a file of its own because the
/// thumbnail extension, which reads the picture, is built with it too.
enum DesignPackage {
    /// The screens, elements, title and canvas settings.
    static let design = "design.json"
    /// The folder of ink, one file for each drawing, named by the drawing's identifier.
    static let ink = "ink"
    /// All of a board's ink as one drawing, as it was saved until file version 3. Still read.
    static let drawing = "drawing.data"
    /// The folder of attached pictures, each named by its identifier.
    static let images = "images"
    /// Quick Look's convention on the Mac for pictures kept inside a document package.
    static let quickLook = "QuickLook"
    /// A picture of the board, for Files and the document browser.
    static let thumbnail = "Thumbnail.jpg"
}
