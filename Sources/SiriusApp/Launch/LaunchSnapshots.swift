import AppKit

// A debug path for reviewing the launch cue without launching Sirius for
// real: `Sirius --launch-snapshots <dir>` renders the pill off every screen
// at 2x, held at a few moments (DictationPill.poseLaunch), to
// <dir>/<name>.png and exits before the socket server starts, as
// OnboardingSnapshots does. The pill is drawn over a plain dark ground, as
// its behind-window blur has nothing to blur off screen. The ring's
// gradient and shape come from a fixed seed, so each run draws the same.
// The blur the sparkle comes in from does not show: a layer render skips
// SwiftUI's blur filter, so the entering shot has only its scale and
// opacity, and the word only its rise and opacity. The ring's band has
// passed the border by about 1.1 s; the pill grows at 0.6 s, so the
// growing shot carries the ring part way, at the width it has reached.
@MainActor
enum LaunchSnapshots {
    static let flag = "--launch-snapshots"

    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // (name, the sparkle's reveal, the pill's grow to "Listening.", the
        // word's reveal, the ring's seconds into its splash).
        let shots: [(name: String, reveal: Double, grow: Double, word: Double, ring: Double?)] = [
            ("1-entering", 0.35, 0, 0, nil),
            ("2-sparkle", 1, 0, 0, nil),
            ("3-ring-0.2s", 1, 0, 0, 0.2),
            ("4-ring-0.4s", 1, 0, 0, 0.4),
            ("5-ring-0.7s", 1, 0, 0, 0.7),
            ("6-ring-1.0s", 1, 0, 0, 1.0),
            ("7-growing", 1, 0.6, 0, 0.62),
            ("8-word-entering", 1, 1, 0.5, nil),
            ("9-listening", 1, 1, 1, nil),
        ]
        let pill = DictationPill(mark: nil)
        for shot in shots {
            var random = SeededGenerator(seed: 7)
            guard let view = pill.poseLaunch(reveal: shot.reveal, grow: shot.grow, word: shot.word, ring: shot.ring,
                                              using: &random) else { continue }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let image = render(view) else {
                FileManager.default.createFile(atPath: directory.path + "/FAILED-\(shot.name)", contents: nil)
                continue
            }
            let url = directory.appendingPathComponent("\(shot.name).png")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
        exit(0)
    }

    // The view at 2x over a dark ground, through its layer tree so the
    // ring's masks show (ComposerSnapshots.render).
    static func render(_ view: NSView) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        return context.makeImage()
    }
}

// SplitMix64, for a ring that is the same in every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
