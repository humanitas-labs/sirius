import AppKit
import SiriusCore
import SwiftUI

// The first step's wordmark, as the onboarding's design frames have it: the
// product name in capitals, Cormorant Garamond Medium at 38 pt, tracked
// 0.62 em, in a pale blue with a soft glow. Tracking adds space after the
// last letter too, so the word is moved right by half of it to sit on its
// optical centre.
struct Wordmark: View {
    let text: String

    static let size: CGFloat = 38
    static let tracking: CGFloat = 0.62 * size
    static let colour = NightSkyPalette.dot

    var body: some View {
        Text(text.uppercased())
            .font(WordmarkFont.font)
            .tracking(Self.tracking)
            .foregroundStyle(Self.colour)
            .shadow(color: Self.colour.opacity(0.35), radius: 12)
            .fixedSize()
            .offset(x: Self.tracking / 2)
    }
}

// Cormorant Garamond Medium (OFL), bundled at Contents/Resources/fonts by
// build-app.sh and registered for the process the first time it is asked
// for. Without the bundle (`swift run`), the system's serif, New York.
enum WordmarkFont {
    static let postScriptName = "CormorantGaramond-Medium"

    @MainActor static let font: Font = {
        if let url = Bundle.main.url(forResource: postScriptName, withExtension: "ttf", subdirectory: "fonts")
            ?? URL(fileURLWithPath: "packaging/fonts/\(postScriptName).ttf") as URL?,
            FileManager.default.fileExists(atPath: url.path) {
            register(url)
        }
        if NSFont(name: postScriptName, size: Wordmark.size) != nil {
            return .custom(postScriptName, fixedSize: Wordmark.size)
        }
        return .system(size: Wordmark.size, weight: .medium, design: .serif)
    }()

    static func register(_ url: URL) {
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            SiriusLog.onboarding.error("couldn't register \(url.lastPathComponent): \(String(describing: error?.takeRetainedValue()))")
        }
    }
}

