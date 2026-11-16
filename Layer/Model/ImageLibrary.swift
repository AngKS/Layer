import ImageIO
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
        // Scaled down as it is decoded, so a large photo is never held at full size.
        guard let cgImage = downsampled(data, longestSide: longestSide) else { return nil }
        let image = UIImage(cgImage: cgImage)
        let hasAlpha: Bool = switch cgImage.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: true
        default: false
        }
        guard let encoded = hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.85) else { return nil }
        return Prepared(data: encoded, image: image)
    }

    /// Decodes image data no larger than `longestSide` pixels along its longer edge, the
    /// right way up, without decoding it at full size first.
    nonisolated static func downsampled(_ data: Data, longestSide: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}

/// The pictures attached to a design. They are kept as the image data saved in the file and
/// decoded when first drawn, at no more than the size they can be shown at. Decoded pictures
/// are a cache: the system empties it when memory runs short, and pictures nothing shows
/// any more are let go once the board has been left alone.
@MainActor @Observable
final class ImageLibrary {
    /// How large a picture is decoded: enough for the largest it is drawn at full zoom
    /// with text kept sharp.
    static let decodedLongestSide: CGFloat = 1600

    @ObservationIgnored private var data: [UUID: Data] = [:]
    @ObservationIgnored private let decoded = NSCache<NSUUID, UIImage>()
    @ObservationIgnored private var decodedIDs: Set<UUID> = []
    /// Changes when a picture is added, so views showing a new picture draw it.
    private var revision = 0

    init(_ saved: [String: Data] = [:]) {
        for (key, picture) in saved {
            if let id = UUID(uuidString: key) { data[id] = picture }
        }
    }

    func image(_ id: UUID?) -> UIImage? {
        _ = revision
        guard let id else { return nil }
        if let image = decoded.object(forKey: id as NSUUID) { return image }
        guard let picture = data[id], let cgImage = ImageImport.downsampled(picture, longestSide: Self.decodedLongestSide) else { return nil }
        let image = UIImage(cgImage: cgImage)
        decoded.setObject(image, forKey: id as NSUUID, cost: cgImage.bytesPerRow * cgImage.height)
        decodedIDs.insert(id)
        return image
    }

    func add(_ prepared: ImageImport.Prepared) -> UUID {
        let id = UUID()
        data[id] = prepared.data
        decoded.setObject(prepared.image, forKey: id as NSUUID)
        decodedIDs.insert(id)
        revision += 1
        return id
    }

    /// Lets go of decoded pictures that nothing on the board shows. Their data stays, so
    /// undoing a deletion brings the picture back.
    func keepDecoded(_ shown: Set<UUID>) {
        for id in decodedIDs.subtracting(shown) {
            decoded.removeObject(forKey: id as NSUUID)
        }
        decodedIDs.formIntersection(shown)
    }
}
