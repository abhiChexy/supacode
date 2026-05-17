import ComposableArchitecture
import SwiftUI

public nonisolated struct AnalyticsClient: Sendable {
  public var capture: @Sendable (_ event: String, _ properties: [String: Any]?) -> Void
  public var identify: @Sendable (_ distinctId: String) -> Void

  public init(
    capture: @escaping @Sendable (_ event: String, _ properties: [String: Any]?) -> Void,
    identify: @escaping @Sendable (_ distinctId: String) -> Void
  ) {
    self.capture = capture
    self.identify = identify
  }
}

extension AnalyticsClient: DependencyKey {
  /// No-op live value in this personal fork. See docs/DECISIONS.md.
  public static let liveValue = AnalyticsClient(
    capture: { _, _ in },
    identify: { _ in }
  )

  public static let testValue = AnalyticsClient(
    capture: { _, _ in },
    identify: { _ in }
  )
}

extension DependencyValues {
  public var analyticsClient: AnalyticsClient {
    get { self[AnalyticsClient.self] }
    set { self[AnalyticsClient.self] = newValue }
  }
}

private struct AnalyticsClientKey: EnvironmentKey {
  static let defaultValue = AnalyticsClient.liveValue
}

extension EnvironmentValues {
  public var analyticsClient: AnalyticsClient {
    get { self[AnalyticsClientKey.self] }
    set { self[AnalyticsClientKey.self] = newValue }
  }
}
