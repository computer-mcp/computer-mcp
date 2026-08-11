import Foundation

@MainActor
protocol OnboardingPreferenceStoring {
  var completedVersion: Int { get }
  func markCompleted(version: Int)
}

@MainActor
struct UserDefaultsOnboardingPreferences: OnboardingPreferenceStoring {
  static let currentVersion = 1
  static let key = "onboarding_version"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var completedVersion: Int {
    defaults.integer(forKey: Self.key)
  }

  func markCompleted(version: Int = Self.currentVersion) {
    defaults.set(version, forKey: Self.key)
  }
}
