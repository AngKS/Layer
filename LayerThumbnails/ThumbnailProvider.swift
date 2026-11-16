import QuickLookThumbnailing
import UIKit

/// Gives Files and Layer's document browser a picture for each design. The app keeps one
/// inside the design's package, of the board as it was last left, so there is nothing to
/// work out here: the picture is read and drawn at the size asked for.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void) {
        let picture = request.fileURL
            .appendingPathComponent(DesignPackage.quickLook)
            .appendingPathComponent(DesignPackage.thumbnail)
        guard let image = UIImage(contentsOfFile: picture.path), image.size.width > 0, image.size.height > 0 else {
            // A design with nothing on it has no picture. The system draws its usual icon.
            handler(nil, nil)
            return
        }
        // As large as fits in what was asked for, without stretching.
        let fit = min(request.maximumSize.width / image.size.width, request.maximumSize.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let reply = QLThumbnailReply(contextSize: size) {
            image.draw(in: CGRect(origin: .zero, size: size))
            return true
        }
        handler(reply, nil)
    }
}
