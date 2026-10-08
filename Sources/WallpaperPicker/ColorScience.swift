import CoreGraphics
import Foundation

// Colour maths for the cards: sRGB <-> CIELAB, a Material-style tonal
// scheme built from a seed colour, and the seed read out of an image.
//
// The original picker asks matugen (Material You, "tonal spot", dark) for
// each wallpaper's scheme. Material works in HCT; here CIELAB LCh stands in
// for it (L* is exactly HCT's tone, hue and chroma are close), which keeps
// the familiar look without porting CAM16.

struct RGB: Equatable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        r = Double((v >> 16) & 0xff) / 255
        g = Double((v >> 8) & 0xff) / 255
        b = Double(v & 0xff) / 255
    }

    var hex: String {
        func byte(_ c: Double) -> Int { Int((min(1, max(0, c)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    // Perceived brightness, as the original's inkOn() reads it.
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }
}

struct Lab: Sendable {
    var l: Double
    var a: Double
    var b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }

    var hue: Double {
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }
}

enum ColorMath {
    private static let white = (x: 0.95047, y: 1.0, z: 1.08883)
    private static let epsilon = 216.0 / 24389.0
    private static let kappa = 24389.0 / 27.0

    static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func toGamma(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    static func lab(_ c: RGB) -> Lab {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        func f(_ t: Double) -> Double { t > epsilon ? cbrt(t) : (kappa * t + 16) / 116 }
        let fx = f(x / white.x), fy = f(y / white.y), fz = f(z / white.z)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    // Linear sRGB for a Lab colour, or nil when it falls outside sRGB.
    private static func linearRGB(_ p: Lab) -> (Double, Double, Double)? {
        let fy = (p.l + 16) / 116
        let fx = fy + p.a / 500
        let fz = fy - p.b / 200
        func finv(_ t: Double) -> Double {
            let t3 = t * t * t
            return t3 > epsilon ? t3 : (116 * t - 16) / kappa
        }
        let y = p.l > kappa * epsilon ? fy * fy * fy : p.l / kappa
        let x = finv(fx) * white.x
        let z = finv(fz) * white.z
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        let lo = -1e-4, hi = 1 + 1e-4
        guard (lo...hi).contains(r), (lo...hi).contains(g), (lo...hi).contains(b) else { return nil }
        return (r, g, b)
    }

    // The colour at tone `l`, hue `h` (degrees) and chroma `c`, with chroma
    // reduced as far as it takes to stay inside sRGB (as HCT does).
    static func rgb(l: Double, c: Double, h: Double) -> RGB {
        let rad = h * .pi / 180
        func at(_ c: Double) -> (Double, Double, Double)? {
            linearRGB(Lab(l: l, a: c * cos(rad), b: c * sin(rad)))
        }
        var best = at(0) ?? (0, 0, 0)
        if let full = at(c) {
            best = full
        } else {
            var lo = 0.0, hi = c
            for _ in 0..<18 {
                let mid = (lo + hi) / 2
                if let v = at(mid) {
                    best = v
                    lo = mid
                } else {
                    hi = mid
                }
            }
        }
        func clamp(_ v: Double) -> Double { min(1, max(0, toGamma(max(0, v)))) }
        return RGB(r: clamp(best.0), g: clamp(best.1), b: clamp(best.2))
    }
}

// The roles a card shows and dresses itself in (Material 3 dark scheme).
struct Scheme: Codable, Equatable, Hashable, Sendable {
    var source: String
    var primary: String
    var onPrimary: String
    var primaryContainer: String
    var secondary: String
    var tertiary: String
    var surfaceContainerLow: String
    var surfaceContainer: String
    var surfaceContainerHigh: String
    var surfaceContainerHighest: String
    var onSurface: String
    var onSurfaceVariant: String
    var outlineVariant: String

    // Tonal spot: primary chroma 36, secondary 16, tertiary 24 turned 60°
    // round the wheel, neutrals 6 and 8. `vividness` scales every chroma
    // (0 gives greys, for a wallpaper with no real colour in it).
    static func make(hue: Double, vividness: Double, source: RGB) -> Scheme {
        func tone(_ chroma: Double, _ h: Double, _ t: Double) -> String {
            ColorMath.rgb(l: t, c: chroma * vividness, h: h).hex
        }
        return Scheme(
            source: source.hex,
            primary: tone(36, hue, 80),
            onPrimary: tone(36, hue, 20),
            primaryContainer: tone(36, hue, 30),
            secondary: tone(16, hue, 80),
            tertiary: tone(24, hue + 60, 80),
            surfaceContainerLow: tone(6, hue, 10),
            surfaceContainer: tone(6, hue, 12),
            surfaceContainerHigh: tone(6, hue, 17),
            surfaceContainerHighest: tone(6, hue, 22),
            onSurface: tone(6, hue, 90),
            onSurfaceVariant: tone(8, hue, 80),
            outlineVariant: tone(8, hue, 30)
        )
    }

    static let neutral = make(hue: 40, vividness: 0.15, source: RGB(r: 0.3, g: 0.3, b: 0.3))
}

enum Palette {
    struct Result: Sendable {
        var scheme: Scheme
        // The seed's hue, or nil for a wallpaper without real colour.
        var hue: Double?
        var lightness: Double
    }

    // Reads the seed colour of an image (k-means in Lab, then Material's
    // scoring: favour colours that are both common and colourful) and
    // builds its scheme.
    static func analyze(_ image: CGImage) -> Result {
        let n = 96
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        var labs: [Lab] = []
        labs.reserveCapacity(n * n)
        if drawn {
            for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 250 {
                labs.append(ColorMath.lab(RGB(r: Double(pixels[i]) / 255,
                                              g: Double(pixels[i + 1]) / 255,
                                              b: Double(pixels[i + 2]) / 255)))
            }
        }
        guard !labs.isEmpty else {
            return Result(scheme: .neutral, hue: nil, lightness: 50)
        }

        let clusters = kMeans(labs, k: 8, iterations: 12)
        let total = Double(labs.count)
        let lightness = labs.reduce(0) { $0 + $1.l } / total

        // Colourful clusters, each scored by the share of the image within
        // 20° of its hue plus a pull towards chroma 48 (Material's Score).
        let colourful = clusters.filter { $0.center.chroma >= 8 && Double($0.count) / total >= 0.01 }
        var best: (lab: Lab, score: Double)?
        for c in colourful {
            var share = 0.0
            for o in colourful {
                var dh = abs(o.center.hue - c.center.hue)
                if dh > 180 { dh = 360 - dh }
                if dh <= 20 { share += Double(o.count) / total }
            }
            let chroma = c.center.chroma
            let score = share * 100 * 0.7 + (chroma - 48) * (chroma < 48 ? 0.1 : 0.3)
            if best == nil || score > best!.score { best = (c.center, score) }
        }

        if let seed = best?.lab {
            let source = ColorMath.rgb(l: seed.l, c: seed.chroma, h: seed.hue)
            return Result(scheme: .make(hue: seed.hue, vividness: 1, source: source), hue: seed.hue, lightness: lightness)
        }
        // No real colour: a near-grey scheme on the dominant cluster's hue.
        let dominant = clusters.max { $0.count < $1.count }!.center
        let source = ColorMath.rgb(l: dominant.l, c: dominant.chroma, h: dominant.hue)
        return Result(scheme: .make(hue: dominant.hue, vividness: 0.25, source: source), hue: nil, lightness: lightness)
    }

    private struct Cluster {
        var center: Lab
        var count: Int
    }

    private static func kMeans(_ points: [Lab], k: Int, iterations: Int) -> [Cluster] {
        func dist(_ p: Lab, _ q: Lab) -> Double {
            let dl = p.l - q.l, da = p.a - q.a, db = p.b - q.b
            return dl * dl + da * da + db * db
        }
        // k-means++ seeding with a fixed generator, so a wallpaper always
        // gets the same scheme.
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func random() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Double(rng >> 11) / Double(1 << 53)
        }
        var centers = [points[points.count / 2]]
        var nearest = points.map { dist($0, centers[0]) }
        while centers.count < min(k, points.count) {
            let sum = nearest.reduce(0, +)
            guard sum > 0 else { break }
            var target = random() * sum
            var pick = points.count - 1
            for (i, d) in nearest.enumerated() {
                target -= d
                if target <= 0 { pick = i; break }
            }
            centers.append(points[pick])
            for i in points.indices { nearest[i] = min(nearest[i], dist(points[i], points[pick])) }
        }

        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<iterations {
            var sums = [(l: Double, a: Double, b: Double, n: Int)](repeating: (0, 0, 0, 0), count: centers.count)
            for (i, p) in points.enumerated() {
                var bestIndex = 0
                var bestDist = Double.infinity
                for (j, c) in centers.enumerated() {
                    let d = dist(p, c)
                    if d < bestDist { bestDist = d; bestIndex = j }
                }
                assignment[i] = bestIndex
                sums[bestIndex].l += p.l
                sums[bestIndex].a += p.a
                sums[bestIndex].b += p.b
                sums[bestIndex].n += 1
            }
            for j in centers.indices where sums[j].n > 0 {
                let n = Double(sums[j].n)
                centers[j] = Lab(l: sums[j].l / n, a: sums[j].a / n, b: sums[j].b / n)
            }
        }
        var counts = [Int](repeating: 0, count: centers.count)
        for a in assignment { counts[a] += 1 }
        return centers.indices.filter { counts[$0] > 0 }.map { Cluster(center: centers[$0], count: counts[$0]) }
    }
}
