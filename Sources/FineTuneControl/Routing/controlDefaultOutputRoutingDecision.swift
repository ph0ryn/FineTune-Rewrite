/// Routing admission for default-following apps, independent of the actual observed OS default.
public enum ControlDefaultOutputRoutingDecision: Equatable, Sendable {
  case followObserved
  case routeToApprovedUID(String)
}
