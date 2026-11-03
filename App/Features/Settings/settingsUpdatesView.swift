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

  var body: some View {
    switch capability {
    case .unavailable(let reason):
      VStack(spacing: DesignTokens.Spacing.md) {
        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 32))
        Text("Updates are unavailable in this build.").font(DesignTokens.Typography.rowName)
        Text(reason).font(DesignTokens.Typography.rowDescription).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(DesignTokens.Spacing.xxl)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .available(let read, let actions):
      let current = read()
      Form {
        Section("Software Updates") {
          Toggle(
            "Automatic updates",
            isOn: SettingsUpdateBindings(read: read, actions: actions).automaticChecks
          )
          .help("Check for new versions automatically")
          HStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
              Text("Last checked")
              if let date = current.lastChecked {
                Text(date, style: .relative).foregroundStyle(.secondary)
              } else {
                Text("Never checked").foregroundStyle(.secondary)
              }
            }
            Spacer()
            if current.isChecking { ProgressView().controlSize(.small) }
            Button("Check Now", action: actions.checkNow).disabled(current.isChecking)
          }
          if let error = current.error {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
        }
      }
      .formStyle(.grouped).controlSize(.small)
    }
  }
}
