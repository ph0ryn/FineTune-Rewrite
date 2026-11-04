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

  var body: some View {
    Form {
      Section("Software Updates") {
        switch capability {
        case .unavailable(let reason):
          HStack {
            automaticUpdatesLabel
            Spacer()
            Text("Not configured").foregroundStyle(.secondary)
            Toggle("Automatic updates", isOn: .constant(false)).labelsHidden().disabled(true)
              .accessibilityValue("Not configured")
          }
          HStack {
            lastCheckedLabel(date: nil)
            Spacer()
            checkNowButton
          }
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Updates are unavailable in this build.")
            Text(reason).foregroundStyle(.secondary)
          }
          .font(DesignTokens.Typography.rowDescription)
        case .available(let read, let actions):
          let current = read()
          HStack {
            automaticUpdatesLabel
            Spacer()
            Toggle(
              "Automatic updates",
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
      Button("Check Now") {}.disabled(!canCheckNow)
    case .available(_, let actions):
      Button("Check Now", action: actions.checkNow).disabled(!canCheckNow)
    }
  }

  private var automaticUpdatesLabel: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text("Automatic updates")
      Text("Check for new versions automatically")
        .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
    }
  }

  private func lastCheckedLabel(date: Date?) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      Text("Last checked")
      if let date {
        Text("Version \(version ?? "unavailable") · \(date, style: .relative)")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      } else {
        Text("Version \(version ?? "unavailable") · Never checked")
          .font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
      }
    }
  }
}
