import Foundation
import SupacodeSettingsShared

/// No-op in this personal fork. Type + Configuration are preserved so call
/// sites and existing tests compile unchanged. See docs/DECISIONS.md.
enum AppTelemetry {
  struct Configuration: Equatable {
    let apiKey: String
    let host: String

    init?(infoDictionary: [String: Any]) {
      guard
        let apiKey = Self.string(infoDictionary["PostHogAPIKey"]),
        let host = Self.string(infoDictionary["PostHogHost"])
      else {
        return nil
      }

      self.apiKey = apiKey
      self.host = host
    }

    private static func string(_ value: Any?) -> String? {
      guard let value = value as? String else { return nil }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
  }

  static func isEnabled(settings: GlobalSettings, isDebugBuild: Bool) -> Bool {
    settings.analyticsEnabled && !isDebugBuild
  }

  @MainActor
  static func setup(
    settings: GlobalSettings,
    infoDictionary: [String: Any],
    hardwareUUID: String? = HardwareInfo.uuid
  ) {
    // intentionally empty
  }
}
