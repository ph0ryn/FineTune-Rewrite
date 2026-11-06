import FineTuneDomain

extension AudioController {
  func changed(_ identifiers: [String], explicitRetry: Bool = false) {
    revision &+= 1
    for identifier in Set(identifiers) {
      if explicitRetry {
        routeRetryRevisions[identifier, default: 0] &+= 1
        captureRetryFailures[identifier] = nil
      }
      appRevisions[identifier] = revision
      for record in owned.values where record.key.appIdentifier == identifier {
        deliverLevels(record)
        enqueueUpdate(record)
      }
      reconcile(identifier, explicitRetry: explicitRetry)
    }
  }

  func reconcileAll(explicitRetry: Bool = false) {
    for application in applications {
      reconcile(application.identifier, explicitRetry: explicitRetry)
    }
  }

  func reconcile(_ identifier: String, force: Bool = false, explicitRetry: Bool = false) {
    guard let application = app(identifier), !settingsStore.isIgnored(identifier),
      case .userInitiated(let sessionID) = captureIntent
    else {
      stopRoutes(for: identifier, cancelPending: false)
      return
    }
    guard hasApplications, hasOutputs, applicationObservationFailure == nil,
      outputObservationFailure == nil, !knownPermissionDenied,
      captureRetryFailures[identifier] == nil
    else { return }
    let available = Dictionary(uniqueKeysWithValues: outputs.map { ($0.uid, $0) })
    let wanted: Set<String>
    let followsDefault = settingsStore.isFollowingDefault(for: identifier)
    if followsDefault {
      wanted = Set(defaultRoutingUID().map { [$0] } ?? [])
    } else {
      wanted =
        settingsStore.getSelectedDeviceUIDs(for: identifier)
        ?? Set(settingsStore.getDeviceRouting(for: identifier).map { [$0] } ?? [])
    }
    var chosen = orderedUIDs(wanted).compactMap { available[$0] }
    if settingsStore.getDeviceSelectionMode(for: identifier) != .multi {
      chosen = Array(chosen.prefix(1))
    }
    if chosen.isEmpty, !followsDefault, let fallback = defaultOutputUID.flatMap({ available[$0] }) {
      chosen = [fallback]
    }
    guard !chosen.isEmpty else {
      stopRoutes(for: identifier, cancelPending: false)
      routeFailures[identifier] = AudioRouteFailure(
        kind: .unavailable, stage: "outputs",
        message: "No output is currently available for \(identifier).")
      return
    }
    let plan = AudioRoutePlan(
      processRevision: application.processRevision, sessionID: sessionID, outputs: chosen)
    if !force, let previous = plans[identifier], plan.hasSameBindings(as: previous),
      (!explicitRetry && routingTasks[identifier] != nil)
        || ((active[identifier] ?? [:]).count == plan.outputs.count
          && usableActiveRoutes(identifier, plan: plan).count == plan.outputs.count)
    {
      return
    }
    if !explicitRetry, inFlightPreparations.contains(where: { $0.identifier == identifier }) {
      // Task cancellation cannot cancel an OS permission call. Keep its actual result and only
      // invalidate stale activation; the latest observed binding replaces one pending plan.
      generations[identifier] = (generations[identifier] ?? 0) &+ 1
      plans[identifier] = plan
      pendingReconciliations[identifier] = force || pendingReconciliations[identifier] == true
      return
    }
    guard let runtime else {
      routeFailures[identifier] = AudioRouteFailure(
        kind: .unavailable, stage: "prepare", message: "The live audio runtime is unavailable.")
      return
    }
    cancelPreparation(for: identifier)
    let generation = (generations[identifier] ?? 0) &+ 1
    generations[identifier] = generation
    plans[identifier] = plan
    let workID = AudioRouteWorkID(identifier: identifier, generation: generation)
    let retryRevision = (
      capture: captureRetryRevision, route: routeRetryRevisions[identifier] ?? 0
    )
    let task = Task { [weak self] in
      guard let self else { return }
      await self.apply(
        plan, identifier: identifier, generation: generation, runtime: runtime, force: force,
        retryRevision: retryRevision)
      self.finishRoutingWork(workID)
    }
    routingTaskIDs[identifier] = workID
    routingTasks[identifier] = task
    allRoutingTasks[workID] = task
  }

  func finishRoutingWork(_ workID: AudioRouteWorkID) {
    let identifier = workID.identifier
    if routingTaskIDs[identifier] == workID {
      routingTaskIDs[identifier] = nil
      routingTasks[identifier] = nil
    }
    allRoutingTasks[workID] = nil
    guard routingTasks[identifier] == nil,
      !inFlightPreparations.contains(where: { $0.identifier == identifier }),
      let force = pendingReconciliations.removeValue(forKey: identifier)
    else { return }
    reconcile(identifier, force: force)
  }

  func prepareRoute(
    _ request: AudioRouteRequest, runtime: any AudioRoutingRuntime
  ) async throws -> any PreparedAudioRoute {
    let workID = AudioRouteWorkID(
      identifier: request.key.appIdentifier, generation: request.key.generation)
    inFlightPreparations.insert(workID)
    defer { inFlightPreparations.remove(workID) }
    return try await runtime.prepare(request)
  }

  func defaultRoutingUID() -> String? {
    switch readDefaultRoutingDecision() {
    case .followObserved: defaultOutputUID
    case .routeToApprovedUID(let uid): uid
    }
  }

  func defaultPlanIsCurrent(_ identifier: String) -> Bool {
    guard settingsStore.isFollowingDefault(for: identifier) else { return true }
    guard let plan = plans[identifier] else { return false }
    return plan.outputs.map(\.uid) == (defaultRoutingUID().map { [$0] } ?? [])
  }

  func usableActiveRoutes(_ identifier: String, plan: AudioRoutePlan) -> [String: AudioRouteKey] {
    (active[identifier] ?? [:]).filter { uid, key in
      guard let record = owned[key], !record.isClosing, let state = routeObservations[key],
        state.phase == .committed || state.phase == .firstApplied,
        state.failure == nil, state.cleanupFailure == nil,
        let output = plan.outputs.first(where: { $0.uid == uid })
      else { return false }
      return record.processRevision == plan.processRevision && record.sessionID == plan.sessionID
        && record.output.bindingRevision == output.bindingRevision
    }
  }

  func apply(
    _ plan: AudioRoutePlan, identifier: String, generation: UInt64,
    runtime: any AudioRoutingRuntime, force: Bool,
    retryRevision: (capture: UInt64, route: UInt64)
  ) async {
    var candidates: [ManagedAudioRoute] = []
    var attemptedAcquisition = false
    var operationSessionID = plan.sessionID
    let reusable = force ? [:] : usableActiveRoutes(identifier, plan: plan)
    let retained = Set(reusable.values)
    let previous = owned.values.filter {
      $0.key.appIdentifier == identifier && !retained.contains($0.key)
    }
    do {
      for output in plan.outputs where reusable[output.uid] == nil {
        try current(identifier, generation: generation)
        let key = AudioRouteKey(
          appIdentifier: identifier, deviceUID: output.uid, generation: generation)
        let state = try makeState(identifier: identifier, output: currentOutput(output))
        attemptedAcquisition = true
        let handle = try await prepareRoute(
          AudioRouteRequest(
            key: key, processRevision: plan.processRevision, initialState: state,
            captureIntent: .userInitiated(sessionID: plan.sessionID)), runtime: runtime)
        guard handle.key == key else {
          handle.cancel()
          _ = await handle.retire()
          throw AudioRouteFailure(
            kind: .bindingChanged, stage: "prepare",
            message: "The prepared owner returned a different route binding.")
        }
        let record = ManagedAudioRoute(
          handle: handle, processRevision: plan.processRevision, sessionID: plan.sessionID,
          output: output)
        candidates.append(record)
        owned[key] = record
        routeObservations[key] = AudioRouteObservation(key: key, phase: .prepared)
        handle.onObservation = { [weak self] observation in self?.receive(observation) }
        try current(identifier, generation: generation)
      }
      if !previous.isEmpty {
        for record in candidates {
          let receipt = try await record.handle.startMuted(state: makeState(record))
          receive(receipt)
          try receiptSucceeded(receipt)
          try current(identifier, generation: generation)
        }
        for record in candidates {
          try await waitUntilArmed(record.key)
          try current(identifier, generation: generation)
        }
        for record in previous {
          operationSessionID = record.sessionID
          try await retire(record)
        }
      }
      operationSessionID = plan.sessionID
      try current(identifier, generation: generation)
      var committed = reusable
      for record in candidates {
        let receipt = try await record.handle.commit(state: makeState(record))
        receive(receipt)
        try receiptSucceeded(receipt)
        try current(identifier, generation: generation)
        guard let phase = routeObservations[record.key]?.phase,
          phase == .committed || phase == .firstApplied
        else {
          throw AudioRouteFailure(
            stage: "commit", message: "The runtime did not confirm the render-permit commit.")
        }
        committed[record.key.deviceUID] = record.key
        deliverLevels(record)
        enqueueUpdate(record)
      }
      active[identifier] = committed
      captureRetryFailures[identifier] = nil
      // Reused owners can fail while a new output commits; partial success is not recovery.
      if usableActiveRoutes(identifier, plan: plan).count == plan.outputs.count {
        routeFailures[identifier] = nil
      }
    } catch {
      let isCurrent = generations[identifier] == generation && captureIntent != .none
      let reason = failure(error, stage: "route")
      let sameRetry =
        captureIntent == .userInitiated(sessionID: plan.sessionID)
        && captureRetryRevision == retryRevision.capture
        && (routeRetryRevisions[identifier] ?? 0) == retryRevision.route
      if sameRetry, attemptedAcquisition, !(error is CancellationError), reason.kind != .cancelled,
        reason.kind != .permissionDenied || operationSessionID == plan.sessionID
      {
        // A passive revision change is not a fresh permission attempt. Preserve the real
        // returned failure even when its binding is stale; only an explicit retry releases it.
        captureRetryFailures[identifier] = reason
        routeFailures[identifier] = reason
        if reason.kind == .permissionDenied { knownPermissionDenied = true }
      }
      if isCurrent, sameRetry,
        !(error is CancellationError && !defaultPlanIsCurrent(identifier))
      {
        routeFailures[identifier] = reason
        if reason.kind == .permissionDenied,
          captureIntent == .userInitiated(sessionID: operationSessionID)
        {
          knownPermissionDenied = true
        }
      }
      // Callback-closed candidates cannot provide continuity: their OS IO still runs and their
      // taps still mute the source. Retire them without waiting for the next app to produce data.
      for record in candidates {
        record.cancel()
        scheduleRetirement(record)
      }
    }
  }

  func current(_ identifier: String, generation: UInt64) throws {
    try Task.checkCancellation()
    guard generations[identifier] == generation, captureIntent != .none,
      app(identifier) != nil, !settingsStore.isIgnored(identifier), defaultPlanIsCurrent(identifier)
    else { throw CancellationError() }
  }

  func currentOutput(_ previous: AudioOutputDescriptor) -> AudioOutputDescriptor {
    outputs.first { $0.uid == previous.uid && $0.bindingRevision == previous.bindingRevision }
      ?? previous
  }

  func makeState(_ record: ManagedAudioRoute) throws -> AudioOutputState {
    try makeState(identifier: record.key.appIdentifier, output: currentOutput(record.output))
  }

  func makeState(identifier: String, output: AudioOutputDescriptor) throws -> AudioOutputState {
    let appGain = gain(for: identifier)
    let profile: AutoEQProfile?
    if output.supportsAutoEQ, let selection = settingsStore.getAutoEQSelection(for: output.uid),
      selection.isEnabled
    {
      profile = profileLookup(selection.profileID)
    } else {
      profile = nil
    }
    let settings = settingsStore.appSettings
    if settings.loudnessCompensationEnabled && output.volume == nil {
      throw AudioRouteFailure(
        kind: .unavailable, stage: "loudness",
        message: "The unboosted device volume is unavailable for \(output.uid).")
    }
    var loudness = LoudnessEqualizerSettings()
    loudness.enabled = settings.loudnessEqualizationEnabled
    return AudioOutputState(
      revision: appRevisions[identifier] ?? revision,
      effectiveGain: appGain * boost(for: identifier).rawValue * output.processingGain,
      isMuted: isMuted(for: identifier) || output.isMuted == true,
      processing: TapInitialState(
        eqSettings: settingsStore.getEQSettings(for: identifier), autoEQProfile: profile,
        autoEQPreampEnabled: settingsStore.autoEQPreampEnabled,
        // Unity is only an unused input while loudness is disabled, never an observed scalar.
        loudnessVolume: appGain * (output.volume ?? 1),
        loudnessCompensationEnabled: settings.loudnessCompensationEnabled,
        loudnessEqualizerSettings: loudness))
  }

  func deliverLevels(_ record: ManagedAudioRoute) {
    let output = currentOutput(record.output)
    let identifier = record.key.appIdentifier
    record.handle.requestLevels(
      AudioOutputLevels(
        revision: appRevisions[identifier] ?? revision,
        effectiveGain: gain(for: identifier) * boost(for: identifier).rawValue
          * output.processingGain,
        isMuted: isMuted(for: identifier) || output.isMuted == true,
        effectiveLoudnessVolume: gain(for: identifier)
          * (output.volume ?? record.output.volume ?? 1)))
  }

  func enqueueUpdate(_ record: ManagedAudioRoute) {
    guard !record.isClosing, updateTasks[record.key] == nil else { return }
    updateTasks[record.key] = Task { [weak self] in
      guard let self else { return }
      defer { self.updateTasks[record.key] = nil }
      do {
        while self.owned[record.key] != nil && !record.isClosing && self.captureIntent != .none {
          let state = try self.makeState(record)
          let receipt = try await record.handle.update(state: state)
          self.receive(receipt)
          try self.receiptSucceeded(receipt)
          if (self.appRevisions[record.key.appIdentifier] ?? self.revision) == state.revision {
            break
          }
        }
      } catch {
        let reason = self.failure(error, stage: "update")
        if self.owned[record.key] != nil && !(error is CancellationError)
          && !(record.isClosing && reason.kind == .cancelled)
        {
          self.routeFailures[record.key.appIdentifier] = reason
        }
      }
    }
  }

  func routeFailureForDisplay(
    _ value: AudioRouteObservation, record: ManagedAudioRoute
  ) -> AudioRouteFailure? {
    if record.isClosing && value.failure?.kind == .cancelled { return value.cleanupFailure }
    return value.failure ?? value.cleanupFailure
  }

  func receive(_ incoming: AudioRouteObservation) {
    guard let record = owned[incoming.key] else { return }
    let prior = routeObservations[incoming.key]
    let phase: AudioRoutePhase
    if let prior, incoming.phase != .failed, prior.phase == .failed, incoming.phase != .retired {
      phase = prior.phase
    } else if let prior, incoming.phase != .failed,
      phaseOrder(prior.phase) > phaseOrder(incoming.phase)
    {
      phase = prior.phase
    } else {
      phase = incoming.phase
    }
    let failure = incoming.failure ?? prior?.failure
    let cleanupFailure = incoming.cleanupFailure ?? prior?.cleanupFailure
    let hasPeak =
      (phase == .committed || phase == .firstApplied) && failure == nil && cleanupFailure == nil
    let merged = AudioRouteObservation(
      key: incoming.key, phase: phase,
      acceptedRevision: maxRevision(prior?.acceptedRevision, incoming.acceptedRevision),
      appliedRevision: maxRevision(prior?.appliedRevision, incoming.appliedRevision),
      failure: failure, cleanupFailure: cleanupFailure,
      peakLevel: hasPeak ? incoming.peakLevel : nil)
    routeObservations[incoming.key] = merged
    if let error = merged.failure ?? merged.cleanupFailure {
      armWaiters.removeValue(forKey: incoming.key)?.resume(throwing: error)
    } else {
      if phase == .armed || phase == .committed || phase == .firstApplied {
        armWaiters.removeValue(forKey: incoming.key)?.resume()
      }
      if phase == .retired {
        armWaiters.removeValue(forKey: incoming.key)?.resume(throwing: CancellationError())
      }
    }
    if let waiter = retirementWaiters[incoming.key] {
      if let error = retirementFailure(merged, priorFailure: waiter.priorFailure) {
        retirementWaiters.removeValue(forKey: incoming.key)?.continuation.resume(throwing: error)
      } else if phase == .retired {
        retirementWaiters.removeValue(forKey: incoming.key)?.continuation.resume()
      }
    }
    if let error = routeFailureForDisplay(incoming, record: record) {
      let relevant =
        generations[incoming.key.appIdentifier] == incoming.key.generation
        || active[incoming.key.appIdentifier]?.values.contains(incoming.key) == true
      if relevant {
        routeFailures[incoming.key.appIdentifier] = error
        if error.kind == .permissionDenied,
          captureIntent == .userInitiated(sessionID: record.sessionID)
        {
          knownPermissionDenied = true
        }
        if error.kind == .bindingChanged, prior?.failure != error,
          phase != .retiring, phase != .retired, retirementTasks[incoming.key] == nil,
          captureIntent != .none
        {
          reconcile(record.key.appIdentifier, force: true)
        }
      }
    }
    // A retired acknowledgement releases ownership even when the same observation reports an error.
    if phase == .retired {
      owned[incoming.key] = nil
      retirementTasks[incoming.key] = nil
      if active[incoming.key.appIdentifier]?[incoming.key.deviceUID] == incoming.key {
        active[incoming.key.appIdentifier]?[incoming.key.deviceUID] = nil
      }
    }
  }

  func receiptSucceeded(_ value: AudioRouteObservation) throws {
    let observed = routeObservations[value.key]
    if let error = observed?.failure ?? observed?.cleanupFailure ?? value.failure
      ?? value.cleanupFailure
    {
      throw error
    }
  }

  func waitUntilArmed(_ key: AudioRouteKey) async throws {
    if let value = routeObservations[key] {
      try receiptSucceeded(value)
      if value.phase == .armed || value.phase == .committed || value.phase == .firstApplied {
        return
      }
    }
    try await withCheckedThrowingContinuation { armWaiters[key] = $0 }
  }

  func retirementFailure(
    _ value: AudioRouteObservation, priorFailure: AudioRouteFailure?
  ) -> AudioRouteFailure? {
    // Closing admission may make an in-flight start/commit record cancellation after the baseline.
    // Neither that cancellation nor the historical primary fault is a teardown failure.
    if let error = value.cleanupFailure { return error }
    guard let error = value.failure, error != priorFailure, error.kind != .cancelled else {
      return nil
    }
    return error
  }

  func retire(_ record: ManagedAudioRoute) async throws {
    if let value = routeObservations[record.key], value.phase == .retired {
      if let error = value.cleanupFailure { throw error }
      return
    }
    try await retirement(record).value
  }

  /// Register before the first await: handoff, stop and shutdown join one native retirement.
  func retirement(_ record: ManagedAudioRoute) -> Task<Void, any Error> {
    record.isClosing = true
    if let existing = retirementTasks[record.key] { return existing }
    let priorFailure = routeObservations[record.key]?.failure
    let task = Task<Void, any Error> {
      // Keep a terminal failed result while its native owner is retained. A later handoff joins
      // that failure instead of automatically retrying cleanup when its candidate finally arms.
      defer {
        if self.owned[record.key] == nil { self.retirementTasks[record.key] = nil }
      }
      do {
        self.updateTasks[record.key]?.cancel()
        switch await record.handle.retire() {
        case .retired: self.receive(AudioRouteObservation(key: record.key, phase: .retired))
        case .failed(let error): throw error
        case .pending:
          if let value = self.routeObservations[record.key] {
            if let error = self.retirementFailure(value, priorFailure: priorFailure) { throw error }
            if value.phase == .retired { return }
          }
          try await withCheckedThrowingContinuation {
            self.retirementWaiters[record.key] = AudioRetirementWaiter(
              continuation: $0, priorFailure: priorFailure)
          }
        }
        if let value = self.routeObservations[record.key],
          let error = self.retirementFailure(value, priorFailure: priorFailure)
        {
          throw error
        }
      } catch {
        self.routeFailures[record.key.appIdentifier] = self.failure(error, stage: "retire")
        throw error
      }
    }
    retirementTasks[record.key] = task
    return task
  }

  func scheduleRetirement(_ record: ManagedAudioRoute) {
    guard owned[record.key] != nil, routeObservations[record.key]?.phase != .retired else { return }
    _ = retirement(record)
  }

  func cancelPreparation(for identifier: String) {
    routingTasks[identifier]?.cancel()
    routingTasks[identifier] = nil
    routingTaskIDs[identifier] = nil
    pendingReconciliations[identifier] = nil
    for key in Array(armWaiters.keys) where key.appIdentifier == identifier {
      armWaiters.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }
    for record in owned.values
    where record.key.appIdentifier == identifier
      && active[identifier]?[record.key.deviceUID] != record.key
    {
      record.cancel()
      scheduleRetirement(record)
    }
  }

  func stopRoutes(for identifier: String, cancelPending: Bool = true) {
    generations[identifier] = (generations[identifier] ?? 0) &+ 1
    if cancelPending || !inFlightPreparations.contains(where: { $0.identifier == identifier }) {
      cancelPreparation(for: identifier)
    }
    pendingReconciliations[identifier] = nil
    plans[identifier] = nil
    for record in owned.values where record.key.appIdentifier == identifier {
      record.cancel()
      scheduleRetirement(record)
    }
  }

  func maxRevision(_ first: UInt64?, _ second: UInt64?) -> UInt64? {
    switch (first, second) {
    case (let a?, let b?): max(a, b)
    case (let a?, nil): a
    case (nil, let b?): b
    case (nil, nil): nil
    }
  }

  func phaseOrder(_ phase: AudioRoutePhase) -> Int {
    switch phase {
    case .prepared: 0
    case .accepted: 1
    case .started: 2
    case .armed: 3
    case .committed: 4
    case .firstApplied: 5
    case .retiring, .failed: 6
    case .retired: 7
    }
  }
}
