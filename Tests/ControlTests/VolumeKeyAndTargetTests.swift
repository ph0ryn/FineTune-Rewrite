import FineTuneControl
import FineTuneDomain
import Testing

@Suite("Control: VolumeKeyPlanner and TargetAppResolver")
@MainActor
struct VolumeKeyAndTargetTests {
  @Test("VolumeKeyPlanner applies tier curves, mute transitions, and DDC 80ms repeat throttling")
  func volumeKeyPlannerBehavior() {
    var planner = VolumeKeyPlanner()

    let mute = planner.plan(
      event: .muteToggle, tier: .software, currentGain: 0.25, currentMute: false,
      step: .normal, nowNanoseconds: 0)
    #expect(mute?.gain == nil)
    #expect(mute?.mute == true)
    #expect(mute?.sliderFraction == 0.5)
    #expect(mute?.displayedMute == true)
    #expect(mute?.feedbackGain == nil)

    let up = planner.plan(
      event: .volumeUp(isRepeat: false), tier: .software, currentGain: 0.25, currentMute: true,
      step: .coarse, nowNanoseconds: 0)
    #expect(up?.mute == false)
    #expect(up?.displayedMute == false)
    #expect(abs((up?.sliderFraction ?? 0) - 0.625) < 1e-6)
    #expect(abs((up?.gain ?? 0) - Float(0.625 * 0.625)) < 1e-6)
    #expect(up?.feedbackGain == up?.gain)

    let downToZero = planner.plan(
      event: .volumeDown(isRepeat: false), tier: .hardware, currentGain: 0.05, currentMute: false,
      step: .coarse, nowNanoseconds: 0)
    #expect(downToZero?.gain == 0)
    #expect(downToZero?.mute == true)
    #expect(downToZero?.displayedMute == true)
    #expect(downToZero?.feedbackGain == 1)

    let firstRepeat = planner.plan(
      event: .volumeUp(isRepeat: true), tier: .ddc, currentGain: 0.5, currentMute: false,
      step: .normal, nowNanoseconds: 1_000_000_000)
    #expect(firstRepeat != nil)
    let throttled = planner.plan(
      event: .volumeUp(isRepeat: true), tier: .ddc, currentGain: 0.5, currentMute: false,
      step: .normal, nowNanoseconds: 1_050_000_000)
    #expect(throttled == nil)
    let allowedAfter80ms = planner.plan(
      event: .volumeUp(isRepeat: true), tier: .ddc, currentGain: 0.5, currentMute: false,
      step: .normal, nowNanoseconds: 1_080_000_000)
    #expect(allowedAfter80ms != nil)

    #expect(
      planner.plan(
        event: .volumeUp(isRepeat: false), tier: .software, currentGain: 0.5, currentMute: false,
        step: .normal, nowNanoseconds: 0, stepMultiplier: 0) == nil)
    #expect(
      planner.plan(
        event: .volumeUp(isRepeat: false), tier: .software, currentGain: 0.5, currentMute: false,
        step: .normal, nowNanoseconds: 0, stepMultiplier: .nan) == nil)
  }

  @Test(
    "TargetAppResolver filters system daemons, prefers audible frontmost, and keeps sticky fallback"
  )
  func targetAppResolverPriorityAndStickyFallback() {
    let frontmost = MutableBox<String?>("com.apple.systemsoundserverd")
    let resolver = TargetAppResolver(
      ownBundleID: "com.finetune.app", frontmostBundleIDProvider: { frontmost.value })

    // Filters own bundle ID and audio daemons; falls back to first audible candidate.
    let first = resolver.resolveTargetBundleID(audibleCandidates: [
      "com.finetune.app", "com.apple.systemsoundserverd", "com.apple.coreaudiod", "com.spotify",
      "com.apple.Safari",
    ])
    #expect(first == "com.spotify")

    // Frontmost audible candidate wins and becomes sticky when focus moves to own app.
    frontmost.value = "com.apple.Safari"
    #expect(
      resolver.resolveTargetBundleID(audibleCandidates: ["com.spotify", "com.apple.Safari"])
        == "com.apple.Safari")

    frontmost.value = "com.finetune.app"
    #expect(
      resolver.resolveTargetBundleID(audibleCandidates: ["com.spotify", "com.apple.Safari"])
        == "com.apple.Safari")

    // When no audible apps remain, uses external frontmost or lastExternalFrontmost.
    resolver.handleActivation(bundleID: "com.apple.Music")
    resolver.handleActivation(bundleID: "com.finetune.app")
    #expect(resolver.resolveTargetBundleID(audibleCandidates: []) == "com.apple.Music")

    frontmost.value = "com.external.Editor"
    #expect(resolver.resolveTargetBundleID(audibleCandidates: []) == "com.external.Editor")
  }

  @Test("Audio daemons are never retained as activation or fallback targets")
  func audioDaemonsAreNotTargetCandidates() {
    let ownBundleID = "com.finetune.app"
    let activationResolver = TargetAppResolver(
      ownBundleID: ownBundleID, frontmostBundleIDProvider: { nil })
    for daemon in ["com.apple.systemsoundserverd", "com.apple.coreaudiod"] {
      activationResolver.handleActivation(bundleID: daemon)
    }
    #expect(activationResolver.resolveTargetBundleID(audibleCandidates: []) == nil)

    let daemonFrontmost = MutableBox<String?>("com.apple.coreaudiod")
    let frontmostResolver = TargetAppResolver(
      ownBundleID: ownBundleID, frontmostBundleIDProvider: { daemonFrontmost.value })
    #expect(frontmostResolver.resolveTargetBundleID(audibleCandidates: []) == nil)

    #expect(
      activationResolver.resolveTargetBundleID(
        audibleCandidates: [ownBundleID, "com.apple.coreaudiod", "com.spotify"]) == "com.spotify")
  }
}
