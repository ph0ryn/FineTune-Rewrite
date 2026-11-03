import FineTuneControl
import Foundation
import Observation

/// OS event registration lives in composition. This consumer never launches URLs or forks tasks.
@Observable
@MainActor
final class URLAutomationController {
  private let commandHandler: any AudioCommandHandling
  private(set) var lastPlan: URLAutomationPlan?

  init(commandHandler: any AudioCommandHandling) { self.commandHandler = commandHandler }

  @discardableResult
  func handleURL(_ url: URL) -> URLAutomationPlan {
    let plan = URLAutomationParser.parse(url)
    lastPlan = plan
    for command in plan.commands { commandHandler.perform(command) }
    return plan
  }
}
