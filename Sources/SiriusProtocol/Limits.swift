// Placeholders that show the shape (TODO(copy): the values). Text lengths
// count Unicode code points, so every implementation counts the same.
public enum LimitName: String, Sendable, Codable {
    case maxRequestBytes, readDeadlineSeconds, maxConnectionsPerAgent, maxBlocks, maxTextChars
    case maxToastChars, maxNotifyChars, maxSpeakChars, maxImageBytesDecoded, maxImagePixels
    case maxImageFrames, maxAudioSeconds, maxQueued
}

public enum Limits {
    // Whole frame, checked before parsing.
    public static let maxRequestBytes = 8 * 1024 * 1024
    public static let readDeadlineSeconds = 5
    // A frame takes longer to carry and to check the longer it is, so both
    // ends scale their deadline with the frame's size, an agent response's
    // length: the helper waits its base (SIRIUS_TIMEOUT, default 10 s)
    // plus a transfer allowance, and the app reads within a total budget
    // readBudgetSeconds whose window of inactivity stays
    // readDeadlineSeconds. The allowance is one second per
    // frameBytesPerSecond beyond freeFrameBytes; the first bytes are free,
    // so a toast or a spoken line never waits longer than before.
    public static let frameBytesPerSecond = 512 * 1024
    public static let freeFrameBytes = 64 * 1024
    // The largest frame at the allowance's rate, plus the window: what a
    // whole frame may take however slowly it is written.
    public static var readBudgetSeconds: Double {
        Double(readDeadlineSeconds)
            + Double(maxRequestBytes - freeFrameBytes) / Double(frameBytesPerSecond)
    }
    public static let maxConnectionsPerAgent = 8
    public static let maxBlocks = 32
    // Across all text blocks.
    public static let maxTextChars = 20_000
    public static let maxToastChars = 280
    public static let maxNotifyChars = 1_000
    public static let maxSpeakChars = 2_000
    public static let maxImageBytesDecoded = 6 * 1024 * 1024
    public static let maxImagePixels = 4096 * 4096
    public static let maxImageFrames = 1
    public static let maxAudioSeconds = 120
    // Per queue, across all agents.
    public static let maxQueued = 50
}

extension String {
    public var codePoints: Int { unicodeScalars.count }
}
