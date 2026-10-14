import AppKit
import SiriusCore
import CoreImage
import SwiftUI

// Every colour of the onboarding's night sky and the page on it, in one
// place, after the design's onboarding frames and its settings/* variables
// (SettingsPalette), so an update to the design changes only these.
enum NightSkyPalette {
    // The sky's base (the frames' "Gradient", now one colour): settings/bg-top.
    static let base = hex(SettingsPalette.bgTop)
    // The tiny stars' colour.
    static let star = hex(0xE6F0FF)

    // The page: titles and row labels in white at 85%, secondary text in the
    // settings/secondary cool gray (chosen over #575757).
    static let text = Color.white.opacity(0.85)
    static let secondary = hex(SettingsPalette.secondary)
    // settings/success: Allowed.
    static let success = hex(SettingsPalette.success)
    // settings/stroke: the outline pills' and the help button's rim.
    static let stroke = hex(SettingsPalette.stroke)
    // A filled pill, and its label.
    static let primary = hex(0xE6FAFF)
    static let onPrimary = hex(0x050506)
    // The current step's dot, and the wordmark.
    static let dot = hex(0xD4DEF5)
    static let dotOff = Color.white.opacity(0.2)
    // The Claude mark's own orange, in onboarding and Settings.
    static let claude = hex(SettingsPalette.claudeMark)
    // The tagline under the wordmark.
    static let tagline = hex(0xB5D1FF)
    // The transcript in the first turn (white at 85%, as the titles).
    static let transcript = Color.white.opacity(0.85)

    static func hex(_ value: UInt32) -> Color {
        SettingsPalette.color(value)
    }
}

// The frames' sky, drawn once: the base, the seven soft glows ("Light"),
// the rendered clouds (seed 21, peak 1.0, drop 0.05, at 2x) and the tiny
// stars. It never moves: the
// pages crossfade over it (OnboardingView). In the frames' 760 x 540
// coordinates.
struct NightSky: View {
    static let designSize = CGSize(width: 760, height: 540)

    // One glow: an ellipse in a colour at an opacity, blurred by Figma's
    // layer blur radius.
    private struct Glow {
        let rect: CGRect
        let colour: UInt32
        let opacity: Double
        let blur: CGFloat
    }

    private static let glows: [Glow] = [
        Glow(rect: CGRect(x: 70, y: 140, width: 700, height: 380), colour: SettingsPalette.bgMid, opacity: 0.15, blur: 120),
        Glow(rect: CGRect(x: -60, y: 160, width: 260, height: 300), colour: 0x090B14, opacity: 0.60, blur: 100),
        Glow(rect: CGRect(x: 90, y: 405, width: 620, height: 240), colour: 0x0E152E, opacity: 0.90, blur: 90),
        Glow(rect: CGRect(x: -130, y: 358, width: 520, height: 260), colour: 0x131E3D, opacity: 0.85, blur: 100),
        Glow(rect: CGRect(x: 640, y: 70, width: 300, height: 400), colour: 0x1A2536, opacity: 0.70, blur: 110),
        Glow(rect: CGRect(x: 356, y: 335, width: 640, height: 420), colour: SettingsPalette.bgBottom, opacity: 0.38,
             blur: 120),
        Glow(rect: CGRect(x: 399, y: 360, width: 260, height: 140), colour: SettingsPalette.bgBottom, opacity: 0.45,
             blur: 70),
    ]

    var body: some View {
        Group {
            if let image = Self.image {
                Image(decorative: image, scale: Self.scale)
                    .resizable()
            } else {
                NightSkyPalette.base
            }
        }
        .frame(width: Self.designSize.width, height: Self.designSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // The whole sky as one bitmap at 2x, made once: Core Image blurs the
    // glows (a Gaussian of half Figma's radius, as Figma's layer blur), and
    // the clouds and the stars go over them. No grain: Figma's 5% noise
    // reads as speckle at 1:1 on a Retina screen.
    static let scale: CGFloat = 2
    @MainActor static let image: CGImage? = render()

    @MainActor private static func render() -> CGImage? {
        let width = Int(designSize.width * scale), height = Int(designSize.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor(NightSkyPalette.base).cgColor)
        context.fill(bounds)

        let ci = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        for glow in glows {
            guard let layer = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            layer.translateBy(x: 0, y: CGFloat(height))
            layer.scaleBy(x: scale, y: -scale)
            layer.setFillColor(NSColor(NightSkyPalette.hex(glow.colour)).withAlphaComponent(glow.opacity).cgColor)
            layer.fillEllipse(in: glow.rect)
            guard let shape = layer.makeImage() else { continue }
            let blurred = CIImage(cgImage: shape)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(glow.blur / 2 * scale))
                .cropped(to: bounds)
            if let image = ci.createCGImage(blurred, from: bounds) { context.draw(image, in: bounds) }
        }
        if let clouds = SkyImages.clouds?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(clouds, in: bounds)
        }
        // Figma's y runs down; the context's up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        for (x, y, size, opacity) in tinyStars {
            context.setFillColor(NSColor(NightSkyPalette.star).withAlphaComponent(opacity).cgColor)
            context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        }
        return context.makeImage()
    }
}

// The frames' tiny stars (31:11): x, y, diameter, opacity.
extension NightSky {
    static let tinyStars: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (498, 358, 1.5, 0.113), (263, 287, 1, 0.109), (254, 240, 1.5, 0.049), (355, 206, 1, 0.096),
        (560, 460, 1, 0.159), (366, 117, 1, 0.079), (261, 76, 1.5, 0.125), (388, 538, 1.5, 0.076),
        (149, 484, 1.5, 0.066), (346, 191, 1.5, 0.107), (406, 89, 1, 0.073), (583, 401, 1, 0.056),
        (243, 395, 1, 0.106), (357, 350, 1, 0.137), (40, 473, 1, 0.096), (580, 474, 1.5, 0.068),
        (297, 95, 1, 0.083), (551, 27, 1.5, 0.162), (668, 341, 1, 0.154), (24, 374, 1.5, 0.12),
        (475, 440, 1.5, 0.129), (361, 77, 1, 0.136), (473, 149, 1, 0.048), (236, 175, 2, 0.176),
        (397, 29, 1.5, 0.121), (299, 335, 1, 0.145), (266, 517, 1, 0.076), (697, 151, 1, 0.12),
        (684, 534, 1, 0.074), (207, 221, 1, 0.107), (310, 322, 1, 0.118), (471, 496, 1, 0.158),
        (20, 6, 1, 0.063), (315, 78, 1, 0.066), (30, 357, 2, 0.179), (120, 30, 1, 0.15),
        (232, 80, 1.5, 0.056), (665, 66, 1, 0.157), (337, 480, 1, 0.071), (171, 328, 1, 0.124),
        (573, 291, 2, 0.192), (518, 56, 1, 0.063), (87, 447, 1.5, 0.137), (105, 258, 1, 0.148),
        (134, 297, 1, 0.1), (167, 215, 1.5, 0.156), (572, 383, 1, 0.077), (748, 316, 1, 0.093),
        (245, 64, 1, 0.105), (699, 39, 1, 0.158), (9, 311, 1, 0.101), (205, 101, 1, 0.066),
        (527, 301, 1, 0.141), (411, 209, 1.5, 0.104), (138, 301, 1, 0.105), (98, 87, 1, 0.099),
        (245, 468, 1, 0.15), (187, 28, 2, 0.224), (321, 405, 2, 0.193), (114, 220, 1, 0.07),
        (263, 301, 2, 0.205), (209, 308, 1, 0.096), (364, 82, 1, 0.101), (160, 390, 1.5, 0.105),
        (451, 295, 1, 0.158), (388, 244, 1, 0.124), (464, 234, 1.5, 0.067), (529, 8, 1.5, 0.15),
        (739, 427, 1, 0.09), (710, 319, 1.5, 0.123), (735, 72, 1.5, 0.154), (192, 159, 1, 0.151),
        (361, 101, 2, 0.22), (451, 318, 1, 0.052), (507, 375, 1, 0.114),
    ]
}

// The rendered sky images, bundled at Contents/Resources/images by
// build-app.sh from packaging/images: the clouds (clouds.py) and the bloom
// star (star.py, 96 pt at 4 px a point, on black for Screen). Without the
// bundle (`swift run`), packaging/images beside the working directory.
@MainActor
enum SkyImages {
    static let clouds = load("clouds@2x", size: NightSky.designSize)
    static let star = load("star", size: CGSize(width: BloomStar.side, height: BloomStar.side))

    private static func load(_ name: String, size: CGSize) -> NSImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "images")
            ?? URL(fileURLWithPath: "packaging/images/\(name).png")
        guard let image = NSImage(contentsOf: url) else {
            SiriusLog.onboarding.error("the onboarding's \(name).png is missing")
            return nil
        }
        image.size = size
        return image
    }
}

// The Sirius star over the wordmark, on the first page only (39:2): the
// bloom from star.py, 96 pt, turned -15°, in Screen blend over its dark
// ring (105:22, 240 pt, a black band at 35% between 30% and 100% of its
// radius, peaking at 60%), so it reads against the glows. The core
// twinkles: it swells and shrinks by up to 8% on an irregular period of
// about 3–4 s (two slow waves out of step). With Reduce Motion it is still.
struct BloomStar: View {
    static let side: CGFloat = 96
    static let ring: CGFloat = 240
    static let rotation = Angle.degrees(-15)
    // The ring's centre sits this far above the star's (105:22 against 39:2).
    static let ringOffset: CGFloat = -28.6
    // How much of the star the core's swell takes in: its middle, out to here.
    static let coreRadius: CGFloat = 12
    static let twinkle: CGFloat = 0.08

    var twinkles = true

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.30),
                    .init(color: Color(red: 1 / 255, green: 2 / 255, blue: 4 / 255).opacity(0.35), location: 0.60),
                    .init(color: .clear, location: 1),
                ], center: .center, startRadius: 0, endRadius: Self.ring / 2))
                .frame(width: Self.ring, height: Self.ring)
                .offset(y: Self.ringOffset)
            if let star = SkyImages.star {
                ZStack {
                    Image(nsImage: star)
                        .resizable()
                    if twinkles {
                        TimelineView(.animation) { timeline in
                            core(star, scale: 1 + Self.twinkle * Self.wave(timeline.date.timeIntervalSinceReferenceDate))
                        }
                    }
                }
                .frame(width: Self.side, height: Self.side)
                .rotationEffect(Self.rotation)
                .blendMode(.screen)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // The star's middle again, scaled about its centre, in Screen over the
    // whole, so the core brightens as it swells and dims as it shrinks.
    private func core(_ star: NSImage, scale: CGFloat) -> some View {
        Image(nsImage: star)
            .resizable()
            .frame(width: Self.side, height: Self.side)
            .mask(RadialGradient(colors: [.white, .clear], center: .center,
                                 startRadius: 0, endRadius: Self.coreRadius))
            .scaleEffect(scale)
            .opacity(Double(0.5 + 0.5 * (scale - 1) / Self.twinkle))
            .blendMode(.screen)
    }

    // -1...1: two slow waves, 3.1 s and 3.9 s, so no two swells repeat alike.
    static func wave(_ t: TimeInterval) -> CGFloat {
        CGFloat(0.6 * sin(2 * .pi * t / 3.1) + 0.4 * sin(2 * .pi * t / 3.9 + 1.3))
    }
}

