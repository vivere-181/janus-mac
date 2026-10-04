import SwiftUI

/// What a phone is drawn as. Models we have a detailed drawing of (Galaxy S25, S22 Ultra) show their back in the
/// official colours; every other phone shows its front, built from its real screen (size, corner radius and
/// camera cutout, R28) with its own wallpaper colours. The body colour isn't something Android tells, so the owner
/// picks it (Settings → Devices → Color).
enum DeviceShape: Hashable {
    case s25, s22Ultra, front

    var modelName: String? {
        switch self {
        case .s25: "Galaxy S25"
        case .s22Ultra: "Galaxy S22 Ultra"
        case .front: nil
        }
    }

    /// The drawing for a model code family ("SM-S931"); a name only when the phone hasn't said what it is.
    @MainActor static func of(_ device: Device) -> DeviceShape {
        guard device.type == "phone" else { return .front }
        if let model = device.profile?.model {
            switch KnownModels.family(model) {
            case "SM-S931": return .s25
            case "SM-S908": return .s22Ultra
            default: return .front
            }
        }
        let n = (device.announcedName.isEmpty ? device.name : device.announcedName).lowercased()
        if n.contains("sm-s931") || (n.contains("s25") && !["ultra", "+", "plus", "edge", "fe"].contains(where: n.contains)) {
            return .s25
        }
        if n.contains("s22 ultra") || n.contains("sm-s908") { return .s22Ultra }
        return .front
    }
}

/// A body colour: back glass and frame.
struct Finish: Identifiable, Hashable {
    let id: String
    let title: String
    let body: UInt32
    let frame: UInt32
    var light = false

    var bodyColor: Color { Self.color(body) }
    var frameColor: Color { Self.color(frame) }
    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    // Samsung doesn't publish colour codes; these are close visual matches. Ids are the stored values from before.
    static let s25: [Finish] = [
        .init(id: "s25Navy", title: "Navy", body: 0x1F2B4A, frame: 0x2C3A5C),
        .init(id: "s25Icyblue", title: "Icyblue", body: 0xB9CFE4, frame: 0xA7BED6, light: true),
        .init(id: "s25Mint", title: "Mint", body: 0xBFE0D2, frame: 0xAACFBF, light: true),
        .init(id: "s25SilverShadow", title: "Silver Shadow", body: 0xB8BABF, frame: 0xA3A6AC, light: true),
        .init(id: "s25Blueblack", title: "Blueblack", body: 0x1A1D24, frame: 0x2A2E37),
        .init(id: "s25Coralred", title: "Coralred", body: 0xD9776B, frame: 0xC9685D),
        .init(id: "s25Pinkgold", title: "Pinkgold", body: 0xE7C9BF, frame: 0xD8B7AC, light: true),
    ]
    static let s22Ultra: [Finish] = [
        .init(id: "s22uBlack", title: "Phantom Black", body: 0x26272A, frame: 0x3B3C40),
        .init(id: "s22uWhite", title: "Phantom White", body: 0xEDEBE6, frame: 0xD6D3CD, light: true),
        .init(id: "s22uGreen", title: "Green", body: 0x3D5B4C, frame: 0x4D6B5C),
        .init(id: "s22uBurgundy", title: "Burgundy", body: 0x5C2A33, frame: 0x6E3842),
    ]
    /// Samsung's product code carries the colour in the two letters after the model ("SM-S908E" + "ZK"…).
    /// Only codes seen on real phones are mapped; anything else leaves the choice to the owner.
    static func reported(_ p: DeviceProfile?, shape: DeviceShape) -> String? {
        guard let code = p?.colorCode?.uppercased(), let model = p?.model?.uppercased(), code.hasPrefix(model) else { return nil }
        let c = String(code.dropFirst(model.count).prefix(2))
        switch (shape, c) {
        case (.s22Ultra, "ZK"): return "s22uBlack"
        case (.s25, "DB"): return "s25Navy"
        case (.front, "ZK"): return "black"
        default: return nil
        }
    }

    /// Any other phone: the colours most phones come in. Only the frame shows from the front.
    static let generic: [Finish] = [
        .init(id: "black", title: "Black", body: 0x232427, frame: 0x3A3B3F),
        .init(id: "silver", title: "Silver", body: 0xC9CBCF, frame: 0xB4B7BC, light: true),
        .init(id: "white", title: "White", body: 0xEEEDEA, frame: 0xD9D7D2, light: true),
        .init(id: "blue", title: "Blue", body: 0x3E5A86, frame: 0x52709E),
        .init(id: "green", title: "Green", body: 0x4D6B57, frame: 0x5F7E69),
        .init(id: "pink", title: "Pink", body: 0xE6BFC0, frame: 0xD6AAAC, light: true),
        .init(id: "gold", title: "Gold", body: 0xD9C6A2, frame: 0xC8B48E, light: true),
    ]
}

struct DeviceLook: Hashable {
    let shape: DeviceShape
    let finish: Finish
    /// The phone's screen (px), from the phone or from mirroring; nil = a typical 20:9 phone.
    var screen: DeviceProfile.Screen?
    /// The phone's wallpaper colours (Material You), when it reports them.
    var accent: [Color] = []

    var finishes: [Finish] {
        switch shape {
        case .s25: Finish.s25
        case .s22Ultra: Finish.s22Ultra
        case .front: Finish.generic
        }
    }

    /// Width : height of the drawing.
    var aspect: CGFloat {
        switch shape {
        case .s25: return 70.5 / 146.9        // mm
        case .s22Ultra: return 77.9 / 163.3
        case .front:
            let s = screen ?? PhoneFront.typicalScreen
            let bezel = s.w * PhoneFront.bezel
            return (s.w + 2 * bezel) / (s.h + 2 * bezel)
        }
    }

    var colors: (body: Color, frame: Color, light: Bool) { (finish.bodyColor, finish.frameColor, finish.light) }

    /// The phone's colour for glows and badges, lifted so even a black phone shows: its wallpaper colour when only the
    /// front is drawn and the phone reported one, otherwise its body.
    var glow: Color {
        if shape == .front, let a = accent.first { return a }
        return finish.bodyColor.mix(with: .white, by: finish.light ? 0 : 0.35)
    }

    @MainActor static func of(_ device: Device) -> DeviceLook {
        let shape = DeviceShape.of(device)
        let options: [Finish] = switch shape {
        case .s25: Finish.s25
        case .s22Ultra: Finish.s22Ultra
        case .front: Finish.generic
        }
        let stored = (UserDefaults.standard.dictionary(forKey: "deviceLooks") as? [String: String])?[device.id]
        // The owner's choice, else the colour the phone reports (Samsung's product code), else the first.
        let reported = Finish.reported(device.profile, shape: shape)
        let finish = options.first { $0.id == stored } ?? options.first { $0.id == reported } ?? options[0]
        return DeviceLook(shape: shape, finish: finish, screen: device.profile?.screen,
                          accent: (device.profile?.accent ?? []).compactMap { Color(hex: $0) })
    }

    @MainActor static func set(_ finish: Finish, for device: Device) {
        var all = (UserDefaults.standard.dictionary(forKey: "deviceLooks") as? [String: String]) ?? [:]
        all[device.id] = finish.id
        UserDefaults.standard.set(all, forKey: "deviceLooks")
        device.lookVersion += 1
    }
}

extension Device {
    /// "Galaxy S25", "Pixel 9 Pro": from the phone's report, else from its drawing; nil when unknown.
    var modelName: String? { profile?.displayName ?? DeviceShape.of(self).modelName }
}

/// The device drawn at a given height.
struct DeviceArt: View {
    let device: Device
    var height: CGFloat
    var dimmed = false

    var body: some View {
        let _ = device.lookVersion   // redraw when the owner changes the colour or the phone reports what it is
        let look = DeviceLook.of(device)
        Group {
            if device.type == "phone" {
                switch look.shape {
                case .front: PhoneFront(look: look)
                case .s25, .s22Ultra: PhoneBack(look: look)
                }
            } else {
                IconTile(symbol: device.symbol, color: .gray, size: height)
            }
        }
        .saturation(dimmed ? 0.2 : 1)
        .opacity(dimmed ? 0.7 : 1)
        .frame(width: device.type == "phone" ? height * look.aspect : height, height: height)
    }
}

/// Any phone, from the front: its real screen shape with the camera cutout, its wallpaper colours and the time.
struct PhoneFront: View {
    let look: DeviceLook
    /// Border around the screen (bezel and frame), as a share of the screen's width.
    static let bezel: CGFloat = 0.035
    static let typicalScreen = DeviceProfile.Screen(w: 1080, h: 2400)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let s = look.screen ?? Self.typicalScreen
            let border = w * Self.bezel / (1 + 2 * Self.bezel)
            let scale = (w - 2 * border) / s.w
            // Some phones report a token radius (the S22 Ultra says 11 px); below 4% of the width it's not a real corner.
            let screenRadius = (s.radius.flatMap { $0 >= s.w * 0.04 ? $0 : nil } ?? s.w * 0.11) * scale
            let light = look.finish.light
            ZStack(alignment: .topLeading) {
                // Frame (the body's colour), then the black glass edge, then the screen.
                RoundedRectangle(cornerRadius: screenRadius + border, style: .continuous)
                    .fill(LinearGradient(colors: [look.finish.frameColor.mix(with: .white, by: 0.15), look.finish.frameColor,
                                                  look.finish.frameColor.mix(with: .black, by: light ? 0.12 : 0.3)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: screenRadius + border * 0.45, style: .continuous)
                    .fill(Color(white: 0.03))
                    .padding(border * 0.55)
                RoundedRectangle(cornerRadius: screenRadius, style: .continuous)
                    .fill(wallpaper)
                    .padding(border)
                if h >= 70 { clock(width: w - 2 * border, top: border + (s.h * scale) * 0.1) }
                ForEach(Array((s.cutouts ?? [Self.typicalCutout(s)]).enumerated()), id: \.offset) { _, r in
                    if r.count == 4 { cutout(r, scale: scale, origin: border) }
                }
            }
            .frame(width: w, height: h)
            .shadow(color: .black.opacity(h > 60 ? 0.28 : 0.15), radius: h > 60 ? 10 : 1.5, y: h > 60 ? 5 : 0.5)
        }
    }

    /// The phone's own colours (Material You) when it reports them; otherwise an evening sky.
    private var wallpaper: some ShapeStyle {
        let a = look.accent
        let colors: [Color] = a.count >= 2
            ? [a[0].mix(with: .white, by: 0.1), a[1], (a.last ?? a[1]).mix(with: .black, by: 0.55)]
            : [Color(red: 0.36, green: 0.42, blue: 0.68), Color(red: 0.2, green: 0.22, blue: 0.42), Color(red: 0.07, green: 0.08, blue: 0.15)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    /// A centred punch-hole, for phones that haven't reported theirs.
    private static func typicalCutout(_ s: DeviceProfile.Screen) -> [Double] {
        let d = s.w * 0.05, y = s.w * 0.03
        return [s.w / 2 - d / 2, y, s.w / 2 + d / 2, y + d]
    }

    private func cutout(_ r: [Double], scale: CGFloat, origin: CGFloat) -> some View {
        let cw = (r[2] - r[0]) * scale, ch = (r[3] - r[1]) * scale
        // Bounding rects include a margin around the lens; the hole itself is a bit smaller.
        let d = min(cw, ch) * 0.8
        let wide = cw > ch * 1.3
        return Capsule()
            .fill(Color.black)
            .overlay(Capsule().strokeBorder(Color(white: 0.2), lineWidth: max(0.4, d * 0.08)))
            .frame(width: wide ? cw * 0.9 : d, height: d)
            .position(x: origin + (r[0] + r[2]) / 2 * scale, y: origin + (r[1] + r[3]) / 2 * scale)
    }

    private func clock(width: CGFloat, top: CGFloat) -> some View {
        TimelineView(.everyMinute) { context in
            Text(context.date.formatted(.dateTime.hour().minute()))
                .font(.system(size: width * 0.2, weight: .light))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: width * 0.86)
                .frame(maxWidth: .infinity)
                .padding(.top, top)
        }
    }
}

/// A model we have a detailed drawing of, from the back, in its official colour.
struct PhoneBack: View {
    let look: DeviceLook

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // The S22 Ultra is boxier: small corner radius and flat sides.
            let radius = look.shape == .s22Ultra ? w * 0.09 : w * 0.2
            let (body, frame, light) = look.colors
            ZStack {
                // Frame (flat aluminum sides, color-matched).
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(frame.gradient)
                RoundedRectangle(cornerRadius: radius * 0.92, style: .continuous)
                    .fill(LinearGradient(colors: [body.mix(with: .white, by: 0.12), body, body.mix(with: .black, by: 0.18)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(w * 0.025)
                // Glass sheen.
                RoundedRectangle(cornerRadius: radius * 0.92, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.18), .clear, .clear], startPoint: .topLeading, endPoint: .center))
                    .padding(w * 0.025)
                if look.shape == .s22Ultra {
                    s22Cameras(w: w, h: h, light: light, body: body)
                } else {
                    cameras(w: w, h: h, light: light, body: body)
                }
            }
            .shadow(color: .black.opacity(h > 60 ? 0.28 : 0.15), radius: h > 60 ? 10 : 1.5, y: h > 60 ? 5 : 0.5)
        }
    }

    private func lens(_ d: CGFloat, light: Bool, body: Color, periscope: Bool = false) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [body.mix(with: .white, by: light ? 0.1 : 0.35), body.mix(with: .black, by: 0.1)],
                                         startPoint: .top, endPoint: .bottom))
            Circle().fill(Color(white: 0.04)).padding(d * 0.16)
            if periscope {
                // The 10x periscope shows a square prism window.
                RoundedRectangle(cornerRadius: d * 0.05).fill(Color(white: 0.12)).padding(d * 0.3)
            }
            Circle().fill(RadialGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.5).opacity(0.9), .clear],
                                         center: .init(x: 0.35, y: 0.35), startRadius: 0, endRadius: d * 0.3))
                .padding(d * 0.22)
            Circle().fill(.white.opacity(0.55)).frame(width: d * 0.1, height: d * 0.1).offset(x: -d * 0.12, y: -d * 0.12)
        }
        .frame(width: d, height: d)
    }

    /// S22 Ultra: three lenses in a column at the top left; to their right the periscope lens, then the
    /// flash and the laser autofocus sensor.
    @ViewBuilder private func s22Cameras(w: CGFloat, h: CGFloat, light: Bool, body: Color) -> some View {
        let d = w * 0.25
        let x = w * 0.24
        let y0 = h * 0.085
        let gap = d * 1.18
        ForEach(0..<3) { i in
            lens(d, light: light, body: body).position(x: x, y: y0 + CGFloat(i) * gap)
        }
        lens(d, light: light, body: body, periscope: true).position(x: x + d * 1.15, y: y0)
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.98), Color(white: 0.75)], center: .center, startRadius: 0, endRadius: d * 0.12))
            .frame(width: d * 0.24, height: d * 0.24)
            .position(x: x + d * 1.15, y: y0 + gap * 0.85)
        Circle().fill(Color(white: 0.06))
            .frame(width: d * 0.2, height: d * 0.2)
            .position(x: x + d * 1.15, y: y0 + gap * 1.3)
    }

    /// Three separate lenses stacked vertically at the top left, with the flash beside them.
    @ViewBuilder private func cameras(w: CGFloat, h: CGFloat, light: Bool, body: Color) -> some View {
        let d = w * 0.25
        let x = w * 0.27
        let y0 = h * 0.1
        let gap = d * 1.22
        ForEach(0..<3) { i in
            ZStack {
                Circle().fill(LinearGradient(colors: [body.mix(with: .white, by: light ? 0.1 : 0.35), body.mix(with: .black, by: 0.1)],
                                             startPoint: .top, endPoint: .bottom))
                Circle().fill(Color(white: 0.04)).padding(d * 0.16)
                Circle().fill(RadialGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.5).opacity(0.9), .clear],
                                             center: .init(x: 0.35, y: 0.35), startRadius: 0, endRadius: d * 0.3))
                    .padding(d * 0.22)
                Circle().fill(.white.opacity(0.55)).frame(width: d * 0.1, height: d * 0.1).offset(x: -d * 0.12, y: -d * 0.12)
            }
            .frame(width: d, height: d)
            .position(x: x, y: y0 + CGFloat(i) * gap)
        }
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.98), Color(white: 0.75)], center: .center, startRadius: 0, endRadius: d * 0.12))
            .frame(width: d * 0.24, height: d * 0.24)
            .position(x: x + d * 0.95, y: y0 + gap * 0.15)
    }
}
