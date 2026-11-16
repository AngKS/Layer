import Observation
import UIKit

/// Turns a picked image file into what a design keeps: a copy no larger than it needs to
/// be, which keeps design files a reasonable size.
enum ImageImport {
    struct Prepared: Sendable {
        var data: Data
        var image: UIImage
    }

    static let longestSide: CGFloat = 2048

    /// Reads PNG, JPEG or HEIC data. Pictures with transparency are kept as PNG, others
    /// as JPEG. Returns nil if the data isn't a picture.
    static func prepare(_ data: Data) -> Prepared? {
        guard var image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        if longest > longestSide {
            let shrink = longestSide / longest
            let size = CGSize(width: image.size.width * image.scale * shrink, height: image.size.height * image.scale * shrink)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        let hasAlpha: Bool = switch image.cgImage?.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: true
        default: false
        }
        guard let encoded = hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.85) else { return nil }
        return Prepared(data: encoded, image: image)
    }
}

/// The pictures attached to a design, decoded for drawing.
@MainActor @Observable
final class ImageLibrary {
    private var images: [UUID: UIImage] = [:]

    /// Decodes the pictures saved in a design file.
    init(_ saved: [String: Data] = [:]) {
        for (key, data) in saved {
            if let id = UUID(uuidString: key), let image = UIImage(data: data) {
                images[id] = image
            }
        }
    }

    func image(_ id: UUID?) -> UIImage? {
        id.flatMap { images[$0] }
    }

    func add(_ prepared: ImageImport.Prepared) -> UUID {
        let id = UUID()
        images[id] = prepared.image
        return id
    }
}
