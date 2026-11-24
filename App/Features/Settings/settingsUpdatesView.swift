import Foundation
import SwiftUI

struct SettingsUpdatePresentation {
  var automaticallyChecks: Bool
  var lastChecked: Date?
  var isChecking: Bool
  var error: String?
}

@MainActor
struct SettingsUpdateActions {
  let checkNow: () -> Void
  let setAutomaticChecks: (Bool) -> Void
}

/// No update callbacks are invented when this build has no signed rewrite feed.
@MainActor
enum SettingsUpdateCapability {
  case unavailable(reason: String)
  case available(read: () -> SettingsUpdatePresentation, actions: SettingsUpdateActions)
}

@MainActor
struct SettingsUpdateBindings {
  let read: () -> SettingsUpdatePresentation
  let actions: SettingsUpdateActions
  var automaticChecks: Binding<Bool> {
    Binding(get: { read().automaticallyChecks }, set: { actions.setAutomaticChecks($0) })
  }
}

@MainActor
struct SettingsUpdatesView: View {
  let capability: SettingsUpdateCapability
  var version: String? =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  var copy = SettingsUpdatesCopy()

  var body: some View {
    SettingsScrollView {
      SettingsSection(copy.sectionTitle) {
        switch capability {
        case .unavailable(let reason):
          SettingsRow(
            copy.automaticUpdatesTitle, description: copy.automaticUpdatesDescription
          ) {
            HStack(spacing: DesignTokens.Spacing.sm) {
              Text(copy.notConfigured).foregroundStyle(.secondary)
              SettingsNativeToggle(
                isOn: .constant(false), title: copy.automaticUpdatesTitle, isEnabled: false
              )
              .accessibilityValue(copy.notConfigured)
            }
          }
          SettingsRow(
            copy.lastCheckedTitle, description: lastCheckedDescription(date: nil)
          ) {
            checkNowButton
          }
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(copy.unavailable)
            Text(reason).foregroundStyle(.secondary)
          }
          .font(DesignTokens.Typography.rowDescription)
        case .available(let read, let actions):
          let current = read()
          SettingsRow(
            copy.automaticUpdatesTitle, description: copy.automaticUpdatesDescription
          ) {
            SettingsNativeToggle(
              isOn: SettingsUpdateBindings(read: read, actions: actions).automaticChecks,
              title: copy.automaticUpdatesTitle)
          }
          SettingsRow(
            copy.lastCheckedTitle, description: lastCheckedDescription(date: current.lastChecked)
          ) {
            HStack(spacing: DesignTokens.Spacing.sm) {
              if current.isChecking { ProgressView().controlSize(.small) }
              checkNowButton
            }
          }
          if let error = current.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
        }
      }
    }
  }

  var canCheckNow: Bool {
    guard case .available(let read, _) = capability else { return false }
    return !read().isChecking
  }

  /// Both rendered branches use this same control and its real capability-specific action.
  @ViewBuilder var checkNowButton: some View {
    switch capability {
    case .unavailable:
      // An unreachable presentation placeholder, not a supplied update-service action.
      Button(copy.checkNow) {}.disabled(!canCheckNow)
    case .available(_, let actions):
      Button(copy.checkNow, action: actions.checkNow).disabled(!canCheckNow)
    }
  }

  private func lastCheckedDescription(date: Date?) -> String {
    let checked =
      date.map {
        "\(copy.versionLinePrefix(version: version)) \($0.formatted(Date.RelativeFormatStyle()))"
      }
      ?? "\(copy.versionLinePrefix(version: version)) \(copy.neverChecked)"
    return checked
  }
}
