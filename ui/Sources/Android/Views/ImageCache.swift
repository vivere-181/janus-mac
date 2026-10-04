import AppKit
import ImageIO

/// Small images the views show over and over (app icons, album art, contact photos) decoded once, at the size they're
/// shown, instead of on every redraw. A file is looked up by its path, size and modification time, so a file the
/// engine rewrites in place still shows its new picture.
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 24 << 20
        return c
    }()

    /// `points` is the largest side it's shown at; it's decoded for a Retina screen.
    static func file(_ path: String?, points: CGFloat) -> NSImage? {
        guard var path, !path.isEmpty else { return nil }
        if path.hasPrefix("file://") { path = URL(string: path)?.path ?? String(path.dropFirst(7)) }
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let key = "\(path)#\(st.st_size)#\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)#\(Int(points))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return decode(src, points: points, key: key)
    }

    static func data(_ data: Data?, points: CGFloat) -> NSImage? {
        guard let data, !data.isEmpty else { return nil }
        let key = "data#\(data.count)#\(data.hashValue)#\(Int(points))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(src, points: points, key: key)
    }

    private static func decode(_ src: CGImageSource, points: CGFloat, key: NSString) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, Int(points * 2)),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }
}
