import PencilKit
import SwiftUI

/// A drawing's ink as a picture that fills whatever frame it is given. For drawings that
/// are not on the ink canvas, where PencilKit would draw them itself.
struct InkPicture: View {
    let ink: Data?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let ink, let drawing = try? PKDrawing(data: ink), !drawing.strokes.isEmpty {
            Image(uiImage: drawing.image(from: drawing.bounds, scale: displayScale))
                .resizable()
                .accessibilityHidden(true)
        }
    }
}
