import SwiftUI

// Corners are kept tight, like the original's desktop theme.
let cornerScale = 0.4
let favouritePink = Color(red: 1, green: 0.36, blue: 0.48)

extension RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    func color(_ opacity: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: opacity) }
    // Text that reads on this colour.
    var ink: Color { luminance > 0.5 ? .black.opacity(0.78) : .white.opacity(0.9) }
}

struct PickerView: View {
    let model: PickerModel

    var body: some View {
        let fan = model.fan
        Fader(motion: model.motion) {
            ZStack(alignment: .topLeading) {
                Color.black
                BackdropView(wallpaper: model.front,
                             size: CGSize(width: fan.width, height: fan.height),
                             scale: model.backingScale)
                Shade(motion: model.motion, fan: fan)
                    .allowsHitTesting(false)
                BrowseSurface(model: model)
                DeckView(model: model)
                ActionBar(model: model)
                Chrome(model: model)
                if model.displayed.isEmpty {
                    EmptyState(model: model)
                }
            }
            .frame(width: fan.width, height: fan.height)
        }
        .ignoresSafeArea()
    }
}

private struct Fader<Content: View>: View {
    let motion: Motion
    @ViewBuilder let content: Content

    var body: some View {
        content.opacity(motion.shown)
    }
}

// Darkens the top and foot of the preview under the chrome and the deck.
private struct Shade: View {
    let motion: Motion
    let fan: Fan

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 230 * fan.u)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .frame(height: fan.height * 0.5)
        }
        .opacity(1 - 0.9 * motion.peek)
    }
}

// Drag anywhere to browse; click the picture to peek.
private struct BrowseSurface: View {
    let model: PickerModel
    @State private var dragging = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            model.beginDrag()
                        }
                        model.drag(by: value.translation.width)
                    }
                    .onEnded { value in
                        dragging = false
                        model.endDrag(velocity: value.velocity.width)
                    }
            )
            .onTapGesture { model.togglePeek() }
    }
}

// MARK: - The deck

private struct DeckView: View {
    let model: PickerModel

    var body: some View {
        let fan = model.fan
        let m = model.motion
        let pos = m.pos, deal = m.deal, peek = m.peek
        let items = model.displayed
        let lo = max(0, Int(pos.rounded(.down)) - Fan.side - 1)
        let hi = min(items.count - 1, Int(pos.rounded(.up)) + Fan.side + 1)
        ZStack(alignment: .topLeading) {
            if lo <= hi {
                ForEach(Array(lo...hi), id: \.self) { i in
                    let wp = items[i]
                    CardSlot(
                        wallpaper: wp,
                        info: model.library.info[wp.key],
                        placement: fan.place(index: i, pos: pos, deal: deal, peek: peek),
                        fan: fan,
                        isCurrent: model.library.isCurrent(wp),
                        isFavourite: model.library.isFavourite(wp)
                    ) {
                        if i == model.currentIndex { model.applyFront() } else { model.go(i) }
                    }
                    .id(wp.id)
                }
            }
        }
        .frame(width: fan.width, height: fan.height, alignment: .topLeading)
    }
}

private struct CardSlot: View {
    let wallpaper: Wallpaper
    let info: WallpaperInfo?
    let placement: Fan.Placement
    let fan: Fan
    let isCurrent: Bool
    let isFavourite: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        let p = placement
        // Drawn at the front card's size and scaled down, so the card in
        // front is always sharp.
        let k = fan.u * fan.frontScale
        let lift = hovered && p.near < 0.5 ? 20 * fan.u : 0
        CardFace(wallpaper: wallpaper, info: info, k: k, front: p.near,
                 dim: hovered ? 0 : p.dim, isCurrent: isCurrent, isFavourite: isFavourite)
            .frame(width: fan.cardW * fan.frontScale, height: fan.cardH * fan.frontScale)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: onTap)
            .scaleEffect(p.scale / fan.frontScale)
            .offset(y: -lift)
            .animation(.easeOut(duration: 0.17), value: lift)
            .rotationEffect(.radians(p.rotation))
            .position(x: p.x, y: p.y)
            .opacity(p.opacity)
            .zIndex(p.z)
            .allowsHitTesting(p.opacity > 0.5)
    }
}

// One wallpaper as a paint-chip card, dressed in its own scheme.
struct CardFace: View {
    let wallpaper: Wallpaper
    let info: WallpaperInfo?
    let k: Double
    let front: Double
    let dim: Double
    let isCurrent: Bool
    let isFavourite: Bool

    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private var meta: String {
        var parts = [wallpaper.format]
        if let info { parts.append("\(info.width) × \(info.height)") }
        parts.append(Self.bytes.string(fromByteCount: wallpaper.fileSize))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let dress = Dress(info?.scheme)
        let radius = 16 * k * cornerScale
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let base = k / 1.22
        VStack(alignment: .leading, spacing: 0) {
            ThumbImage(wallpaper: wallpaper, placeholder: dress.raised.color)
                .frame(width: 194 * k, height: 121 * k)
                .clipShape(RoundedRectangle(cornerRadius: 10 * k * cornerScale, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if isCurrent {
                        CurrentTag(k: k, dress: dress).padding(7 * k)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isFavourite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 12 * k))
                            .foregroundStyle(favouritePink)
                            .frame(width: 24 * k, height: 24 * k)
                            .background(Circle().fill(.black.opacity(0.42)))
                            .padding(6 * k)
                    }
                }
            Chips(scheme: info?.scheme, dress: dress, k: k)
                .padding(.top, 8 * k)
            Text(wallpaper.name)
                .font(.system(size: 13 * k, weight: .semibold))
                .foregroundStyle(dress.ink.color)
                .lineLimit(1)
                .padding(.top, 9 * k)
                .padding(.horizontal, 2 * k)
            Text(meta)
                .font(.system(size: 10 * k))
                .foregroundStyle(dress.muted.color)
                .lineLimit(1)
                .padding(.top, 2 * k)
                .padding(.horizontal, 2 * k)
        }
        .padding(9 * k)
        .frame(width: 212 * k, height: 299 * k, alignment: .top)
        .background {
            shape
                .fill(dress.surface.color)
                .shadow(color: .black.opacity(0.42 + 0.18 * front),
                        radius: (22 + 18 * front) * base / 2,
                        y: (8 + 10 * front) * base)
        }
        .overlay {
            shape.strokeBorder(dress.line.mix(dress.accent, front * 0.85).color(0.85 + 0.15 * front),
                               lineWidth: max(1, base * (1 + front * 0.6)))
        }
        .overlay {
            if dim > 0 { shape.fill(.black.opacity(dim)) }
        }
        .overlay(alignment: .topTrailing) {
            // The theme's tag, on the card in front.
            if front > 0.6 {
                Text("// " + wallpaper.name.uppercased())
                    .font(.system(size: 10 * k, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(dress.accentInk.color)
                    .padding(.horizontal, 7 * k)
                    .frame(height: 17 * k)
                    .background(dress.accent.color)
                    .frame(maxWidth: 150 * k, alignment: .trailing)
                    .offset(x: -6 * k, y: -8 * k)
                    .opacity((front - 0.6) / 0.4)
            }
        }
    }
}

private struct CurrentTag: View {
    let k: Double
    let dress: Dress

    var body: some View {
        HStack(spacing: 3 * k) {
            Image(systemName: "checkmark")
                .font(.system(size: 9 * k, weight: .heavy))
            Text("current")
                .font(.system(size: 10 * k, weight: .bold))
                .tracking(0.4 * k)
        }
        .foregroundStyle(dress.accentInk.color)
        .padding(.horizontal, 6 * k)
        .frame(height: 19 * k)
        .background(RoundedRectangle(cornerRadius: 9.5 * k * cornerScale).fill(dress.accent.color))
        .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
    }
}

private struct Chips: View {
    let scheme: Scheme?
    let dress: Dress
    let k: Double

    var body: some View {
        let rows: [(String, String)]? = scheme.map {
            [("primary", $0.primary), ("secondary", $0.secondary), ("tertiary", $0.tertiary),
             ("container", $0.primaryContainer), ("surface", $0.surfaceContainerHighest)]
        }
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { i in
                if let rows {
                    let fill = RGB(hex: rows[i].1)
                    HStack {
                        Text(rows[i].0.uppercased())
                            .font(.system(size: 8.5 * k, weight: .bold))
                            .tracking(1.1 * k)
                            .opacity(0.85)
                        Spacer(minLength: 4 * k)
                        Text(rows[i].1.uppercased())
                            .font(.system(size: 9.5 * k, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(fill.ink)
                    .padding(.horizontal, 8 * k)
                    .frame(height: 22 * k)
                    .background(fill.color)
                } else {
                    // Not read yet: a quiet ramp of the card's own colour.
                    dress.raised.mix(RGB(r: 1, g: 1, b: 1), 0.02 + 0.025 * Double(4 - i)).color
                        .frame(height: 22 * k)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7 * k * cornerScale, style: .continuous))
    }
}

struct ThumbImage: View {
    let wallpaper: Wallpaper
    let placeholder: Color
    @State private var image: NSImage?

    init(wallpaper: Wallpaper, placeholder: Color) {
        self.wallpaper = wallpaper
        self.placeholder = placeholder
        _image = State(initialValue: ThumbCache.shared.cached(wallpaper))
    }

    var body: some View {
        placeholder
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: wallpaper.key) {
                if let hit = ThumbCache.shared.cached(wallpaper) {
                    image = hit
                    return
                }
                let loaded = await ThumbCache.shared.load(wallpaper)
                withAnimation(.easeOut(duration: 0.22)) { image = loaded }
            }
    }
}

// MARK: - Above the card in front

private struct ActionBar: View {
    let model: PickerModel

    var body: some View {
        let fan = model.fan, m = model.motion, u = fan.u
        let opacity = max(0, m.deal * 1.6 - 0.6) * (1 - m.peek)
        let top = fan.frontTop - 40 * u - 20 * u + (1 - m.deal) * 60 * u + m.peek * 40 * u
        if let wp = model.front {
            let dress = model.dress
            let current = model.library.isCurrent(wp)
            let favourite = model.library.isFavourite(wp)
            HStack(spacing: 8 * u) {
                Button { model.toggleFavourite() } label: {
                    Image(systemName: favourite ? "heart.fill" : "heart")
                        .font(.system(size: 16 * u, weight: .semibold))
                        .foregroundStyle(favourite ? favouritePink : dress.ink.color)
                        .frame(width: 40 * u, height: 40 * u)
                        .background(Glass(dress: dress, u: u))
                }
                .buttonStyle(.plain)
                Button { model.applyFront() } label: {
                    HStack(spacing: 8 * u) {
                        Image(systemName: current ? "checkmark.circle.fill" : "photo.on.rectangle")
                            .font(.system(size: 14 * u, weight: .semibold))
                        Text(current ? "On your desktop" : "Set wallpaper")
                            .font(.system(size: 14 * u, weight: .semibold))
                        if !current {
                            Text("⏎")
                                .font(.system(size: 11 * u, weight: .bold))
                                .padding(.horizontal, 5 * u)
                                .padding(.vertical, 1 * u)
                                .background(RoundedRectangle(cornerRadius: 3 * u).fill(dress.accentInk.color(0.14)))
                        }
                    }
                    .foregroundStyle(current ? dress.ink.color : dress.accentInk.color)
                    .padding(.horizontal, 16 * u)
                    .frame(height: 40 * u)
                    .background {
                        if current {
                            Glass(dress: dress, u: u)
                        } else {
                            RoundedRectangle(cornerRadius: 20 * u * cornerScale, style: .continuous)
                                .fill(dress.accent.color)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .fixedSize()
            .animation(.easeOut(duration: 0.42), value: dress)
            .position(x: fan.width / 2, y: top + 20 * u)
            .opacity(opacity)
            .allowsHitTesting(opacity > 0.05)
        }
    }
}

struct Glass: View {
    let dress: Dress
    let u: Double
    var opacity = 0.78

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20 * u * cornerScale, style: .continuous)
        shape.fill(dress.surface.color(opacity))
            .overlay(shape.strokeBorder(dress.ink.color(0.14), lineWidth: 1))
    }
}

// MARK: - Top bar, ribbon and keys

private struct Chrome: View {
    let model: PickerModel

    var body: some View {
        let u = model.fan.u
        let dress = model.dress
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8 * u) {
                    TitleBlock(model: model, dress: dress, u: u)
                    Spacer()
                    Segments(dress: dress, u: u, items: SortMode.allCases.map { mode in
                        Segment(label: mode.label, symbol: mode.symbol, selected: model.sort == mode) {
                            model.setSort(mode)
                        }
                    })
                    IconButton(symbol: "eye", dress: dress, u: u) { model.togglePeek() }
                    IconButton(symbol: "xmark", dress: dress, u: u) { model.close() }
                }
                Segments(dress: dress, u: u, items: [
                    Segment(label: "All \(model.library.items.count)", symbol: "photo.stack",
                            selected: model.source == .all) { model.setSource(.all) },
                    Segment(label: "Favourites \(model.library.favourites.count)", symbol: "heart",
                            selected: model.source == .favourites) { model.setSource(.favourites) },
                ])
            }
            .frame(height: 40 * u)
            .padding(.horizontal, 30 * u)
            .padding(.top, 16 * u)

            RibbonView(model: model, dress: dress, u: u)
                .padding(.horizontal, 30 * u)
                .padding(.top, 12 * u)

            Text(model.message ?? "←→ or scroll browse  ·  Enter set  ·  F favourite  ·  S sort  ·  R random  ·  Space peek  ·  Tab favourites  ·  Esc close")
                .font(.system(size: 11 * u, weight: .medium))
                .foregroundStyle(model.message == nil ? dress.muted.color : favouritePink)
                .padding(.horizontal, 12 * u)
                .frame(height: 24 * u)
                .background(Glass(dress: dress, u: u, opacity: 0.6))
                .padding(.top, 10 * u)
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.42), value: dress)
        .modifier(PeekFade(motion: model.motion))
    }
}

private struct PeekFade: ViewModifier {
    let motion: Motion

    func body(content: Content) -> some View {
        content
            .opacity(1 - motion.peek)
            .allowsHitTesting(motion.peek < 0.5)
    }
}

private struct TitleBlock: View {
    let model: PickerModel
    let dress: Dress
    let u: Double

    var body: some View {
        let count = model.displayed.count
        HStack(spacing: 10 * u) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 20 * u, weight: .semibold))
                .foregroundStyle(dress.accent.color)
            VStack(alignment: .leading, spacing: 1 * u) {
                Text("Wallpapers")
                    .font(.system(size: 17 * u, weight: .bold))
                    .foregroundStyle(dress.ink.color)
                Text(count == 0 ? "empty" : "\(model.currentIndex + 1) of \(count)  ·  by \(model.sort.label.lowercased())")
                    .font(.system(size: 11 * u, weight: .medium))
                    .foregroundStyle(dress.muted.color)
                    .monospacedDigit()
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 6)
    }
}

private struct Segment {
    let label: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
}

private struct Segments: View {
    let dress: Dress
    let u: Double
    let items: [Segment]

    var body: some View {
        HStack(spacing: 2 * u) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                Button(action: item.action) {
                    HStack(spacing: 6 * u) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12 * u, weight: .semibold))
                        Text(item.label)
                            .font(.system(size: 13 * u, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(item.selected ? dress.accentInk.color : dress.ink.color)
                    .padding(.horizontal, 12 * u)
                    .frame(height: 32 * u)
                    .background {
                        if item.selected {
                            RoundedRectangle(cornerRadius: 16 * u * cornerScale, style: .continuous)
                                .fill(dress.accent.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4 * u)
        .background(Glass(dress: dress, u: u))
    }
}

private struct IconButton: View {
    let symbol: String
    let dress: Dress
    let u: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14 * u, weight: .semibold))
                .foregroundStyle(dress.ink.color)
                .frame(width: 40 * u, height: 40 * u)
                .background(Glass(dress: dress, u: u))
        }
        .buttonStyle(.plain)
    }
}

// The whole deck in one line: a segment per wallpaper in its colour, a
// bracket round the cards in hand, ticks over favourites and a dot under
// the wallpaper on the desktop. Hover for a glimpse; click or drag to go.
private struct RibbonView: View {
    let model: PickerModel
    let dress: Dress
    let u: Double
    @State private var hoverX: Double?
    @State private var dragging = false
    @State private var width = 1.0

    var body: some View {
        let items = model.displayed
        let pos = model.motion.pos
        let info = model.library.info
        let active = hoverX != nil || dragging
        Canvas { ctx, size in
            let n = items.count
            guard n > 0 else { return }
            let seg = size.width / Double(n)
            let trackH = (active ? 12 : 8) * u
            let ty = (size.height - trackH) / 2

            var track = ctx
            track.clip(to: Path(roundedRect: CGRect(x: 0, y: ty, width: size.width, height: trackH),
                                cornerRadius: trackH / 2))
            for (i, wp) in items.enumerated() {
                let rect = CGRect(x: Double(i) * seg, y: ty, width: seg + 0.6, height: trackH)
                let fill = info[wp.key].map { RGB(hex: $0.scheme.source).color } ?? dress.ink.color(0.14)
                track.fill(Path(rect), with: .color(fill))
            }

            let tickW = max(2, min(seg - 1, 3 * u))
            for (i, wp) in items.enumerated() {
                if model.library.isFavourite(wp) {
                    let x = (Double(i) + 0.5) * seg - tickW / 2
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: ty - 5 * u, width: tickW, height: 3 * u),
                                  cornerRadius: tickW / 2), with: .color(favouritePink))
                }
                if model.library.isCurrent(wp) {
                    let x = (Double(i) + 0.5) * seg - 2 * u
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: ty + trackH + 3 * u, width: 4 * u, height: 4 * u)),
                             with: .color(dress.ink.color))
                }
            }

            // The cards in hand.
            let from = max(0, pos - Double(Fan.side))
            let to = min(Double(n), pos + Double(Fan.side) + 1)
            let bracket = CGRect(x: from * seg - 3 * u, y: ty - 4 * u,
                                 width: max(6 * u, (to - from) * seg + 6 * u), height: trackH + 8 * u)
            ctx.stroke(Path(roundedRect: bracket, cornerRadius: 5 * u * cornerScale),
                       with: .color(dress.ink.color(0.55)), lineWidth: max(1, 1.3 * u))

            // The card in front.
            let markW = max(3 * u, min(seg, 6 * u))
            let mark = Path(roundedRect: CGRect(x: (pos + 0.5) * seg - markW / 2, y: ty - 6 * u,
                                                width: markW, height: trackH + 12 * u),
                            cornerRadius: markW / 2)
            ctx.fill(mark, with: .color(dress.accent.color))
            ctx.stroke(mark, with: .color(.black.opacity(0.35)), lineWidth: 1)
        }
        .frame(height: 26 * u)
        .contentShape(Rectangle())
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { width = $1 }
        })
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    model.setPos(exact(at: value.location.x))
                }
                .onEnded { value in
                    dragging = false
                    model.go(Int(index(at: value.location.x)))
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: hoverX = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoverX, !dragging, !items.isEmpty {
                let i = Int(index(at: hoverX))
                Glimpse(wallpaper: items[i], number: i + 1, dress: dress, u: u)
                    .offset(x: min(max(0, hoverX - 88 * u), width - 176 * u), y: 34 * u)
                    .allowsHitTesting(false)
            }
        }
    }

    private func index(at x: Double) -> Double {
        let n = model.displayed.count
        guard n > 0 else { return 0 }
        return min(Double(n - 1), max(0, (x / width * Double(n)).rounded(.down)))
    }

    // The fractional position under the pointer, so scrubbing moves smoothly.
    private func exact(at x: Double) -> Double {
        let n = Double(model.displayed.count)
        guard n > 0 else { return 0 }
        return min(n - 1, max(0, x / width * n - 0.5))
    }
}

private struct Glimpse: View {
    let wallpaper: Wallpaper
    let number: Int
    let dress: Dress
    let u: Double

    var body: some View {
        VStack(spacing: 5 * u) {
            ThumbImage(wallpaper: wallpaper, placeholder: dress.raised.color)
                .frame(width: 164 * u, height: 102 * u)
                .clipShape(RoundedRectangle(cornerRadius: 8 * u * cornerScale, style: .continuous))
                .id(wallpaper.id)
            Text("\(number)  ·  \(wallpaper.name)")
                .font(.system(size: 11 * u))
                .foregroundStyle(dress.ink.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6 * u)
        .frame(width: 176 * u)
        .background(Glass(dress: dress, u: u, opacity: 0.95))
    }
}

// MARK: - Nothing to show

private struct EmptyState: View {
    let model: PickerModel

    var body: some View {
        let u = model.fan.u
        let dress = Dress(nil)
        let favourites = model.source == .favourites && !model.library.items.isEmpty
        VStack(spacing: 14 * u) {
            Image(systemName: favourites ? "heart" : "photo.on.rectangle.angled")
                .font(.system(size: 44 * u, weight: .light))
                .foregroundStyle(dress.muted.color)
            Text(favourites ? "No favourites yet" : "No wallpapers in \(abbreviated(model.library.folder))")
                .font(.system(size: 20 * u, weight: .semibold))
                .foregroundStyle(dress.ink.color)
            Text(favourites ? "Press F on a wallpaper to add it, Tab to go back."
                            : "Put images in the folder and they appear here straight away.")
                .font(.system(size: 13 * u))
                .foregroundStyle(dress.muted.color)
            if !favourites {
                HStack(spacing: 10 * u) {
                    Button("Open Folder") { model.revealFolder() }
                    Button("Choose Folder…") { model.chooseFolder() }
                }
                .controlSize(.large)
                .padding(.top, 6 * u)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - The preview behind everything

// The card in front at full size. The thumbnail shows at once; the
// full-resolution picture fades in over it when it has loaded.
private struct BackdropView: View {
    let wallpaper: Wallpaper?
    let size: CGSize
    let scale: Double

    private struct Layer: Identifiable {
        let id = UUID()
        let key: String
        let image: NSImage
        let full: Bool
    }

    @State private var layers: [Layer] = []

    var body: some View {
        ZStack {
            ForEach(layers) { layer in
                Image(nsImage: layer.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(.asymmetric(
                        insertion: layer.full ? .opacity : .opacity.combined(with: .scale(scale: 1.035)),
                        removal: .identity))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: wallpaper?.key) {
            guard let wp = wallpaper else {
                layers = []
                return
            }
            let pixels = CGSize(width: size.width * scale, height: size.height * scale)
            if let full = PreviewCache.shared.cached(wp, pixels: pixels) {
                show(wp, full, full: false)
                return
            }
            if let thumb = ThumbCache.shared.cached(wp), layers.last?.key != wp.key {
                show(wp, thumb, full: false)
            }
            // Wait for the deck to slow down before the big load.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            guard let full = await PreviewCache.shared.load(wp, pixels: pixels), !Task.isCancelled else { return }
            show(wp, full, full: layers.last?.key == wp.key)
        }
    }

    private func show(_ wp: Wallpaper, _ image: NSImage, full: Bool) {
        if layers.count > 1 { layers.removeFirst(layers.count - 1) }
        withAnimation(.easeOut(duration: full ? 0.25 : 0.4)) {
            layers.append(Layer(key: wp.key, image: image, full: full))
        }
    }
}
