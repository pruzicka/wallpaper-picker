// Draws the app icon: a hand of wallpaper cards fanned out on a night
// background, the front one lifted, under the colour ribbon.
//
//   swift scripts/make-icon.swift Resources/AppIcon.png
//
// Produces a 1024×1024 PNG; bundle.sh turns it into AppIcon.icns.
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func color(_ hex: String, _ alpha: Double = 1) -> CGColor {
    let v = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(srgbRed: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
                   blue: Double(v & 0xff) / 255, alpha: alpha)
}

struct Palette {
    var skyTop: String
    var skyBottom: String
    var sun: String
    var ridge: String
    var hills: String
    var chips: [String]
    var surface: String
    var accent: String
}

// Left to right round the colour wheel; the sunset card is in front.
let palettes = [
    Palette(skyTop: "#12321F", skyBottom: "#9BD67A", sun: "#F2F5C0", ridge: "#2C5A32", hills: "#0E2414",
            chips: ["#A6D394", "#BACCB0", "#A0CFD2", "#284E1E", "#2E332B"], surface: "#181D17", accent: "#A6D394"),
    Palette(skyTop: "#0F3D5C", skyBottom: "#5ED3C6", sun: "#F5F1C8", ridge: "#1E5F74", hills: "#0B2A3A",
            chips: ["#8ED3E6", "#B1CBD4", "#B9C3EA", "#004E5E", "#2C3437"], surface: "#161D20", accent: "#8ED3E6"),
    Palette(skyTop: "#2B1E5C", skyBottom: "#FF7A59", sun: "#FFD27A", ridge: "#5B2A6E", hills: "#2A1638",
            chips: ["#FFB59F", "#E7BDB1", "#D8C68D", "#723522", "#3D322F"], surface: "#231A1E", accent: "#FFB59F"),
    Palette(skyTop: "#3A1030", skyBottom: "#FF6F91", sun: "#FFE0A3", ridge: "#7A1F4A", hills: "#2B0A1F",
            chips: ["#FFB0C8", "#E3BDC6", "#EFBD94", "#7A2946", "#3A2E31"], surface: "#22191C", accent: "#FFB0C8"),
    Palette(skyTop: "#1A1446", skyBottom: "#9B6CFF", sun: "#FFC2E2", ridge: "#3E2C8C", hills: "#170F38",
            chips: ["#CDBDFF", "#CAC3DC", "#EEB8C9", "#4A3D8C", "#33303A"], surface: "#1B1A22", accent: "#CDBDFF"),
]

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work top-down, like a screen.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func linear(_ colors: [CGColor], from a: CGPoint, to b: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ colors: [CGColor], at c: CGPoint, radius: Double) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

func rounded(_ r: CGRect, _ radius: Double) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: The tile (Apple's grid: 824 pt body, 100 pt margin)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color("#000000", 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(color("#0B0A16"))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
linear([color("#221C44"), color("#0C0B18")], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
// Warm light behind the card in front.
radial([color("#FF7A59", 0.42), color("#FF7A59", 0)], at: CGPoint(x: 512, y: 600), radius: 430)
radial([color("#9B6CFF", 0.25), color("#9B6CFF", 0)], at: CGPoint(x: 230, y: 330), radius: 380)

// MARK: The ribbon

let ribbon = CGRect(x: 196, y: 214, width: 632, height: 20)
ctx.saveGState()
ctx.addPath(rounded(ribbon, 10))
ctx.clip()
let ribbonColors = ["#A6D394", "#7FCF9E", "#5ED3C6", "#8ED3E6", "#7FA8FF", "#9B6CFF", "#CDBDFF",
                    "#FF6F91", "#FFB0C8", "#FF7A59", "#FFB59F", "#FFD27A", "#D8C68D", "#A6D394"]
let seg = ribbon.width / Double(ribbonColors.count)
for (i, c) in ribbonColors.enumerated() {
    ctx.setFillColor(color(c))
    ctx.fill(CGRect(x: ribbon.minX + Double(i) * seg, y: ribbon.minY, width: seg + 1, height: ribbon.height))
}
ctx.restoreGState()
// The bracket round the cards in hand and the marker for the one in front.
ctx.addPath(rounded(ribbon.insetBy(dx: -8, dy: -8).offsetBy(dx: 0, dy: 0)
    .intersection(CGRect(x: 380, y: 0, width: 280, height: 1024)), 8))
ctx.setStrokeColor(color("#FFFFFF", 0.6))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.addPath(rounded(CGRect(x: 510, y: 198, width: 14, height: 52), 7))
ctx.setFillColor(color("#FFB59F"))
ctx.fillPath()

// MARK: The cards

let cardW = 300.0, cardH = 420.0
let pivot = CGPoint(x: 512, y: 1580)
let radius = pivot.y - 610

func drawCard(_ p: Palette, front: Bool) {
    let body = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: front ? -26 : -16), blur: front ? 60 : 36,
                  color: color("#000000", front ? 0.7 : 0.55))
    ctx.addPath(rounded(body, 26))
    ctx.setFillColor(color(p.surface))
    ctx.fillPath()
    ctx.restoreGState()

    // The wallpaper: sky, sun, a ridge and hills.
    let thumb = CGRect(x: body.minX + 18, y: body.minY + 18, width: cardW - 36, height: 165)
    ctx.saveGState()
    ctx.addPath(rounded(thumb, 14))
    ctx.clip()
    linear([color(p.skyTop), color(p.skyBottom)], from: CGPoint(x: 0, y: thumb.minY), to: CGPoint(x: 0, y: thumb.maxY))
    let sun = CGPoint(x: thumb.minX + thumb.width * 0.66, y: thumb.minY + thumb.height * 0.30)
    radial([color(p.sun, 0.55), color(p.sun, 0)], at: sun, radius: 70)
    ctx.setFillColor(color(p.sun))
    ctx.fillEllipse(in: CGRect(x: sun.x - 26, y: sun.y - 26, width: 52, height: 52))
    let ridge = CGMutablePath()
    ridge.move(to: CGPoint(x: thumb.minX, y: thumb.maxY))
    ridge.addLine(to: CGPoint(x: thumb.minX, y: thumb.minY + 100))
    ridge.addLine(to: CGPoint(x: thumb.minX + 62, y: thumb.minY + 64))
    ridge.addLine(to: CGPoint(x: thumb.minX + 110, y: thumb.minY + 96))
    ridge.addLine(to: CGPoint(x: thumb.minX + 168, y: thumb.minY + 52))
    ridge.addLine(to: CGPoint(x: thumb.maxX, y: thumb.minY + 110))
    ridge.addLine(to: CGPoint(x: thumb.maxX, y: thumb.maxY))
    ridge.closeSubpath()
    ctx.addPath(ridge)
    ctx.setFillColor(color(p.ridge))
    ctx.fillPath()
    let hills = CGMutablePath()
    hills.move(to: CGPoint(x: thumb.minX, y: thumb.maxY))
    hills.addLine(to: CGPoint(x: thumb.minX, y: thumb.minY + 132))
    hills.addCurve(to: CGPoint(x: thumb.maxX, y: thumb.minY + 124),
                   control1: CGPoint(x: thumb.minX + 90, y: thumb.minY + 104),
                   control2: CGPoint(x: thumb.minX + 170, y: thumb.minY + 150))
    hills.addLine(to: CGPoint(x: thumb.maxX, y: thumb.maxY))
    hills.closeSubpath()
    ctx.addPath(hills)
    ctx.setFillColor(color(p.hills))
    ctx.fillPath()
    ctx.restoreGState()

    // The palette chips.
    let chips = CGRect(x: thumb.minX, y: thumb.maxY + 14, width: thumb.width, height: 150)
    ctx.saveGState()
    ctx.addPath(rounded(chips, 10))
    ctx.clip()
    for (i, c) in p.chips.enumerated() {
        ctx.setFillColor(color(c))
        ctx.fill(CGRect(x: chips.minX, y: chips.minY + Double(i) * 30, width: chips.width, height: 30))
        // A label and a hex code, as bars.
        let ink = i < 3 ? color("#000000", 0.32) : color("#FFFFFF", 0.32)
        ctx.setFillColor(ink)
        ctx.addPath(rounded(CGRect(x: chips.minX + 12, y: chips.minY + Double(i) * 30 + 12, width: 62, height: 6), 3))
        ctx.addPath(rounded(CGRect(x: chips.maxX - 66, y: chips.minY + Double(i) * 30 + 12, width: 54, height: 6), 3))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // The name and details, as bars.
    ctx.setFillColor(color("#FFFFFF", 0.82))
    ctx.addPath(rounded(CGRect(x: chips.minX + 2, y: chips.maxY + 18, width: 128, height: 14), 7))
    ctx.fillPath()
    ctx.setFillColor(color("#FFFFFF", 0.38))
    ctx.addPath(rounded(CGRect(x: chips.minX + 2, y: chips.maxY + 40, width: 176, height: 9), 4.5))
    ctx.fillPath()

    ctx.addPath(rounded(body.insetBy(dx: 1.5, dy: 1.5), 25))
    ctx.setStrokeColor(front ? color(p.accent, 0.95) : color("#FFFFFF", 0.14))
    ctx.setLineWidth(front ? 5 : 3)
    ctx.strokePath()
}

let angles = [-0.40, -0.21, 0.0, 0.21, 0.40]
// Outer cards first, the front card last.
for i in [0, 4, 1, 3, 2] {
    let theta = angles[i]
    let front = i == 2
    let r = radius + (front ? 70 : 0)
    ctx.saveGState()
    ctx.translateBy(x: pivot.x + r * sin(theta), y: pivot.y - r * cos(theta))
    ctx.rotate(by: theta)
    let s = front ? 1.12 : 0.96
    ctx.scaleBy(x: s, y: s)
    drawCard(palettes[i], front: front)
    if !front {
        // Cards further back sit in shade.
        ctx.addPath(rounded(CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH), 26))
        ctx.setFillColor(color("#000000", abs(theta) > 0.3 ? 0.32 : 0.16))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

// A soft fade at the foot, so the hand sinks into the tile.
linear([color("#0C0B18", 0), color("#0C0B18", 0.85)], from: CGPoint(x: 0, y: 760), to: CGPoint(x: 0, y: 924))
ctx.restoreGState()

// A hairline round the tile.
ctx.addPath(rounded(tile.insetBy(dx: 1.5, dy: 1.5), 184))
ctx.setStrokeColor(color("#FFFFFF", 0.1))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
