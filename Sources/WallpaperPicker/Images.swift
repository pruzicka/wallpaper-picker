import AppKit
import ImageIO
import UniformTypeIdentifiers

// Where the picker keeps what it has worked out.
enum Store {
    static let caches: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WallpaperPicker", isDirectory: true)
    }()

    static let thumbs = caches.appendingPathComponent("thumbs", isDirectory: true)
    static let index = caches.appendingPathComponent("index.json")

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WallpaperPicker", isDirectory: true)
    }()

    static let favourites = support.appendingPathComponent("favourites.json")

    static func prepare() {
        for dir in [thumbs, support] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// Image work that runs off the main thread: reading sizes, making and
// caching thumbnails, reading palettes, loading full-screen previews.
enum Analyzer {
    static func analyze(_ wp: Wallpaper) async -> WallpaperInfo? {
        compute(wp)
    }

    static func compute(_ wp: Wallpaper) -> WallpaperInfo? {
        guard let source = CGImageSourceCreateWithURL(wp.url as CFURL, nil),
              let size = pixelSize(source),
              let thumb = cachedThumb(wp) ?? makeThumb(wp, source: source, size: size)
        else { return nil }
        let palette = Palette.analyze(thumb)
        return WallpaperInfo(width: Int(size.width), height: Int(size.height),
                             scheme: palette.scheme, hue: palette.hue, lightness: palette.lightness)
    }

    static func pixelSize(_ source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0
        else { return nil }
        // Orientations 5–8 are turned a quarter.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func thumbURL(_ wp: Wallpaper) -> URL {
        Store.thumbs.appendingPathComponent(wp.key + ".jpg")
    }

    static func thumbnail(_ wp: Wallpaper) -> CGImage? {
        if let cached = cachedThumb(wp) { return cached }
        guard let source = CGImageSourceCreateWithURL(wp.url as CFURL, nil),
              let size = pixelSize(source)
        else { return nil }
        return makeThumb(wp, source: source, size: size)
    }

    private static func cachedThumb(_ wp: Wallpaper) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(thumbURL(wp) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // Big enough to fill the card in front on a Retina screen (about
    // 640×400 px of picture, cropped to 16:10), whatever the shape.
    private static func makeThumb(_ wp: Wallpaper, source: CGImageSource, size: CGSize) -> CGImage? {
        let need = min(1, max(640 / size.width, 400 / size.height))
        let maxPixel = min(1600, max(64, Int((max(size.width, size.height) * need).rounded(.up))))
        guard let image = downsample(source, maxPixel: maxPixel) else { return nil }
        let target = thumbURL(wp)
        let temp = Store.thumbs.appendingPathComponent(UUID().uuidString + ".tmp")
        if let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(dest) {
                if (try? FileManager.default.moveItem(at: temp, to: target)) == nil {
                    _ = try? FileManager.default.replaceItemAt(target, withItemAt: temp)
                }
            }
            try? FileManager.default.removeItem(at: temp)
        }
        return image
    }

    // The wallpaper at the size it fills `pixels` with (cropped, no upscaling).
    static func preview(_ wp: Wallpaper, covering pixels: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(wp.url as CFURL, nil),
              let size = pixelSize(source)
        else { return nil }
        let scale = min(1, max(pixels.width / size.width, pixels.height / size.height))
        return downsample(source, maxPixel: Int((max(size.width, size.height) * scale).rounded(.up)))
    }

    private static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// Thumbnails in memory (the cards on screen and around them).
final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 120 }

    func cached(_ wp: Wallpaper) -> NSImage? {
        cache.object(forKey: wp.key as NSString)
    }

    func load(_ wp: Wallpaper) async -> NSImage? {
        if let hit = cached(wp) { return hit }
        let cg = await Task.detached(priority: .userInitiated) { Analyzer.thumbnail(wp) }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: wp.key as NSString)
        return image
    }
}

// Full-screen previews: the last few, so going back and forth is instant.
final class PreviewCache: @unchecked Sendable {
    static let shared = PreviewCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 5 }

    private func key(_ wp: Wallpaper, _ pixels: CGSize) -> NSString {
        "\(wp.key)@\(Int(pixels.width))x\(Int(pixels.height))" as NSString
    }

    func cached(_ wp: Wallpaper, pixels: CGSize) -> NSImage? {
        cache.object(forKey: key(wp, pixels))
    }

    func load(_ wp: Wallpaper, pixels: CGSize) async -> NSImage? {
        if let hit = cached(wp, pixels: pixels) { return hit }
        let cg = await Task.detached(priority: .userInitiated) { Analyzer.preview(wp, covering: pixels) }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key(wp, pixels))
        return image
    }
}
