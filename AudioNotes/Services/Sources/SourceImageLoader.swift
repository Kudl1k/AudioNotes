import Foundation
import CoreGraphics

/// Per-library-source cache, bounded by decoded bytes; never retains full originals.
actor SourceImageLoader {
    private let cache = NSCache<NSString, CGImage>()
    init() {
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
    }
    func image(url: URL, maximumDimension: Int) -> CGImage? {
        guard !Task.isCancelled,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(url.path)-\(maximumDimension)-\(attributes[.size] ?? 0)-\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NativeSourceProcessingService.downsample(url: url, maximumDimension: maximumDimension), !Task.isCancelled else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
