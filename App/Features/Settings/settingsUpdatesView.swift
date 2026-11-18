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
    Form {
      Section(copy.sectionTitle) {
        switch capability {
        case .unavailable(let reason):
          HStack {
            automaticUpdatesLabel
            Spacer()
            Text(copy.notConfigured).foregroundStyle(.secondary)
            Toggle(copy.automaticUpdatesTitle, isOn: .constant(false)).labelsHidden().disabled(true)
              .accessibilityValue(copy.notConfigured)
          }
          HStack {
            lastCheckedLabel(date: nil)
            Spacer()
            checkNowButton
          }
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(copy.unavailable)
            Text(reason).foregroundStyle(.secondary)
          }
          .font(DesignTokens.Typography.rowDescription)
        case .available(let read, let actions):
          let current = read()
          HStack {
            automaticUpdatesLabel
            Spacer()
            Toggle(
              copy.automaticUpdatesTitle,
              isOn: SettingsUpdateBindings(read: read, actions: actions).automaticChecks
            )
            .labelsHidden()
          }
          HStack {
            lastCheckedLabel(date: current.lastChecked)
            Spacer()
            if current.isChecking { ProgressView().controlSize(.small) }
            checkNowButton
          }
          if let error = current.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
        }
      }
    }
    .formStyle(.grouped).controlSize(.small)
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

  private var automaticUpdatesLabel: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(copy.automaticUpdatesTitle)
      Text(copy.automaticUpdatesDescription)
        .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
    }
  }

  private func lastCheckedLabel(date: Date?) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text(copy.lastCheckedTitle)
      if let date {
        Text("\(copy.versionLinePrefix(version: version)) \(date, style: .relative)")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      } else {
        Text("\(copy.versionLinePrefix(version: version)) \(copy.neverChecked)")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      }
    }
  }
}
