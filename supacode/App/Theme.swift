import SwiftUI

/// Design tokens for the orchestrator chrome. Per spec §7.5.6 — Conductor.build
/// reference. Dark mode only in v1.
enum Theme {
  enum Color {
    static let backgroundPrimary = SwiftUI.Color(red: 0.051, green: 0.051, blue: 0.055)  // #0d0d0e
    static let backgroundSecondary = SwiftUI.Color(red: 0.075, green: 0.075, blue: 0.086)  // #131316
    static let backgroundTertiary = SwiftUI.Color(red: 0.051, green: 0.051, blue: 0.055)  // #0d0d0e
    static let backgroundElevated = SwiftUI.Color(red: 0.102, green: 0.102, blue: 0.122)  // #1a1a1f
    static let borderSubtle = SwiftUI.Color(red: 0.133, green: 0.133, blue: 0.149)  // #222226
    static let textPrimary = SwiftUI.Color(red: 0.929, green: 0.929, blue: 0.933)  // #ededee
    static let textSecondary = SwiftUI.Color(red: 0.604, green: 0.604, blue: 0.627)  // #9a9aa0
    static let textTertiary = SwiftUI.Color(red: 0.369, green: 0.369, blue: 0.392)  // #5e5e64
    static let accent = SwiftUI.Color(red: 0.231, green: 0.510, blue: 0.965)  // #3b82f6
    static let statusSuccess = SwiftUI.Color(red: 0.063, green: 0.725, blue: 0.506)  // #10b981
    static let statusWarning = SwiftUI.Color(red: 0.961, green: 0.620, blue: 0.043)  // #f59e0b
    static let statusError = SwiftUI.Color(red: 0.937, green: 0.267, blue: 0.267)  // #ef4444
  }

  enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
  }

  enum Radius {
    static let pill: CGFloat = 6
    static let card: CGFloat = 8
    static let input: CGFloat = 10
  }

  enum Font {
    static let body = SwiftUI.Font.system(size: 13)
    static let sidebarRow = SwiftUI.Font.system(size: 12.5)
    static let metadata = SwiftUI.Font.system(size: 11)
    static let headerSection = SwiftUI.Font.system(size: 11, weight: .semibold)
    static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    static let monoSmall = SwiftUI.Font.system(size: 11, design: .monospaced)
    static let monoTiny = SwiftUI.Font.system(size: 10, design: .monospaced)
  }

  enum Motion {
    static let messageFade = Animation.easeOut(duration: 0.12)
    static let toolExpand = Animation.easeOut(duration: 0.16)
    static let pulse = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
  }
}

extension View {
  /// Subtle 1pt border in `Theme.Color.borderSubtle`.
  func themeBorder(_ radius: CGFloat = Theme.Radius.card) -> some View {
    self.overlay(
      RoundedRectangle(cornerRadius: radius)
        .stroke(Theme.Color.borderSubtle, lineWidth: 1)
    )
  }
}
