import SwiftUI

// The design's settings/* variables, which the onboarding and Settings
// share. Secondary is the cool gray #5C6880, chosen over #575757, for all
// secondary text. The app has
// no Settings window yet; when it comes, it takes its colours from here,
// with the Claude mark in its own orange and no AGENTS section header.
enum SettingsPalette {
    static let bgTop: UInt32 = 0x030409
    static let bgMid: UInt32 = 0x050610
    static let bgBottom: UInt32 = 0x1D2C4F
    static let stroke: UInt32 = 0x171719
    static let success: UInt32 = 0xBFFFC1
    static let secondary: UInt32 = 0x5C6880
    // Not a settings/* variable: the Claude mark, here and in onboarding.
    static let claudeMark: UInt32 = 0xD97757

    static func color(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}
