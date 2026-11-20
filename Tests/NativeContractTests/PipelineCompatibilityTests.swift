import CoreAudio
import Foundation
import NativeAudio
import Testing

@testable import FineTuneDomain
@testable import FineTunePlatform

private enum CompatPipelineSignal {
  static func makeABLBuffer(frames: Int, channels: UInt32, fill: (Int, UInt32) -> Float) -> (
    AudioBuffer, UnsafeMutablePointer<Float>
  ) {
    let sampleCount = frames * Int(channels)
    let ptr = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
    for frame in 0..<frames {
      for ch in 0..<channels {
        ptr[frame * Int(channels) + Int(ch)] = fill(frame, ch)
      }
    }
    let buf = AudioBuffer(
      mNumberChannels: channels,
      mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
      mData: UnsafeMutableRawPointer(ptr)
    )
    return (buf, ptr)
  }

  static func rms(
    _ ptr: UnsafePointer<Float>, frames: Int, channels: Int, channel: Int, skip: Int = 0
  ) -> Float {
    var sum: Double = 0
    let count = frames - skip
    for frame in skip..<frames {
      let s = Double(ptr[frame * channels + channel])
      sum += s * s
    }
    return Float(sqrt(sum / Double(max(1, count))))
  }

  static func rampOutput(
    initialGain: Float,
    target: Float,
    rampCoefficient: Float,
    frames: Int,
    crossfadeMultiplier: Float = 1.0,
    inputValue: Float = 1.0
  ) -> (samples: [Float], currentGain: Float) {
    let pipeline = AudioPipeline(initialGain: initialGain)
    let (inBuf, inPtr) = makeABLBuffer(frames: frames, channels: 2) { _, _ in inputValue }
    let (outBuf, outPtr) = makeABLBuffer(frames: frames, channels: 2) { _, _ in 0 }
    defer {
      inPtr.deallocate()
      outPtr.deallocate()
    }

    var params = ft_pipeline_default_parameters()
    params.target_gain = target
    params.crossfade_multiplier = crossfadeMultiplier
    params.output_gate_multiplier = 1.0
    params.ramp_coefficient = rampCoefficient
    let status = pipeline.process(input: inBuf, output: outBuf, parameters: params)
    precondition(status == FT_PIPELINE_OK, "Pipeline processing failed: \(status)")
    return (Array(UnsafeBufferPointer(start: outPtr, count: frames * 2)), pipeline.currentGain)
  }
}

// MARK: - CrossfadeState Compatibility

@Suite("Upstream CrossfadeState Compatibility")
struct UpstreamCrossfadeStateCompatibilityTests {

  @Test("Initial idle state invariants")
  func initialIdleState() {
    let state = CrossfadeState()
    #expect(state.phase == .idle)
    #expect(state.progress == 0)
    #expect(!state.isActive)
    #expect(!state.isWarmupComplete)
    #expect(!state.isCrossfadeComplete)
    #expect(state.primaryMultiplier == 1)
    #expect(state.secondaryMultiplier == 1)
  }

  @Test("Equal-power invariants p^2 + s^2 == 1 and monotonicity across crossfade")
  func equalPowerAndMonotonicity() {
    var state = CrossfadeState()
    state.beginWarmup()
    state.totalSamples = 4096
    _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples)
    state.beginCrossfading()

    // Exact crossfade start boundary: cos(0) and sin(0) are exact in Float32.
    #expect(state.primaryMultiplier == 1)
    #expect(state.secondaryMultiplier == 0)

    var prevPrimary: Float = 2
    var prevSecondary: Float = -1

    for step in 0...40 {
      if step > 0 {
        _ = state.updateProgress(samples: 128)
      }
      let p = state.primaryMultiplier
      let s = state.secondaryMultiplier
      #expect(p >= -1e-6 && p <= 1 + 1e-6)
      #expect(s >= -1e-6 && s <= 1 + 1e-6)
      let powerSum = p * p + s * s
      // Tolerance policy: the measured worst-case Float32 identity error is
      // ~1.2e-7 (rounded progress plus Float32 cos/sin), so 1e-4 stays far above
      // the achievable error, while linear-crossfade-scale failures (~0.1-1.0)
      // still fail. Loosening further would only hide narrower regressions.
      #expect(abs(powerSum - 1.0) < 1e-4, "Expected p^2+s^2=1, got \(powerSum)")
      #expect(p <= prevPrimary + 1e-6)
      #expect(s >= prevSecondary - 1e-6)
      prevPrimary = p
      prevSecondary = s
    }

    // Complete remaining progress to 1.0
    while !state.isCrossfadeComplete {
      _ = state.updateProgress(samples: 512)
    }
    // Same tolerance policy: the measured Float32 |cos(pi/2)| is 4.4e-8 at
    // progress 1, so this bounds the multiplier, not the library ULPs.
    #expect(abs(state.primaryMultiplier) < 1e-4)
    #expect(abs(state.secondaryMultiplier - 1.0) < 1e-4)
  }

  @Test("Warmup requires minimumWarmupSamples before completion")
  func warmupRequiresMinimumSamples() {
    // Warmup length is a compatibility contract: 2048 samples ≈ 42.7ms at 48kHz.
    #expect(CrossfadeState.minimumWarmupSamples == 2048)

    var state = CrossfadeState()
    state.beginWarmup()
    #expect(state.phase == .warmingUp)
    #expect(state.isActive)
    #expect(!state.isWarmupComplete)

    let minSamples = CrossfadeState.minimumWarmupSamples
    let half = max(1, minSamples / 2)
    _ = state.updateProgress(samples: half)
    #expect(!state.isWarmupComplete)
    #expect(state.secondaryMultiplier == 0)

    _ = state.updateProgress(samples: minSamples - half)
    #expect(state.isWarmupComplete)
  }

  @Test("Complete resets state and allows clean second cycle")
  func completeResetsForSecondCycle() {
    var state = CrossfadeState()
    state.beginWarmup()
    _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples)
    state.totalSamples = 24000
    state.beginCrossfading()
    // The configured crossfade length survives the warmup-to-crossfade transition.
    #expect(state.totalSamples == 24000)
    _ = state.updateProgress(samples: 48000)
    #expect(state.isCrossfadeComplete)

    state.complete()
    #expect(state.phase == .idle)
    #expect(state.progress == 0)
    #expect(!state.isActive)
    #expect(state.totalSamples == 0)
    #expect(state.primaryMultiplier == 1)
    #expect(state.secondaryMultiplier == 1)

    state.beginWarmup()
    #expect(state.phase == .warmingUp)
    #expect(!state.isWarmupComplete)
  }

  @Test("Zero and large sample updates never produce NaN or exceed bounds")
  func zeroAndLargeSampleUpdates() {
    var state = CrossfadeState()
    state.beginWarmup()
    _ = state.updateProgress(samples: 0)
    #expect(state.secondarySampleCount == 0)

    _ = state.updateProgress(samples: CrossfadeState.minimumWarmupSamples)
    state.beginCrossfading()
    _ = state.updateProgress(samples: 0)
    #expect(state.progress == 0)

    let finalProgress = state.updateProgress(samples: 10_000_000)
    #expect(finalProgress == 1)
    #expect(state.isCrossfadeComplete)
    #expect(state.primaryMultiplier.isFinite)
    #expect(state.secondaryMultiplier.isFinite)
  }

  @Test("totalSamples=0 usage error still clamps progress to 1 immediately")
  func totalSamplesZeroDefense() {
    var state = CrossfadeState()
    state.beginWarmup()
    // totalSamples is never set: a usage error, defended by max(1, totalSamples).
    state.beginCrossfading()

    let progress = state.updateProgress(samples: 1)
    #expect(progress == 1)
    #expect(state.isCrossfadeComplete)
  }

  @Test("Double complete() is an idempotent reset")
  func doubleCompleteIsIdempotent() {
    var state = CrossfadeState()
    state.beginWarmup()
    state.totalSamples = 48000
    state.beginCrossfading()
    state.progress = 0.7

    state.complete()
    state.complete()

    #expect(state.phase == .idle)
    #expect(state.progress == 0)
    #expect(!state.isActive)
  }

  @Test("beginWarmup during crossfading performs a full reset to warmup multipliers")
  func warmupDuringCrossfadeResets() {
    var state = CrossfadeState()
    state.beginWarmup()
    state.totalSamples = 48000
    state.beginCrossfading()
    state.progress = 0.5

    // Interrupt mid-crossfade with a new warmup (device switch during transition).
    state.beginWarmup()

    #expect(state.phase == .warmingUp)
    #expect(state.progress == 0)
    #expect(state.secondarySampleCount == 0)
    #expect(state.secondarySamplesProcessed == 0)
    #expect(state.primaryMultiplier == 1)
    #expect(state.secondaryMultiplier == 0)
  }

  @Test("Idle multipliers reflect the post-crossfade promotion window")
  func idlePostCrossfadeWindow() {
    // Between the audio thread observing progress >= 1 and the owner calling
    // complete(), an idle state with progress 1 must promote the secondary path.
    var state = CrossfadeState()
    state.progress = 1.0
    #expect(state.primaryMultiplier == 0)
    #expect(state.secondaryMultiplier == 1)

    state.progress = 0.5
    #expect(state.primaryMultiplier == 1)
    #expect(state.secondaryMultiplier == 1)
  }
}

// MARK: - OutputGate Compatibility

@Suite("Upstream OutputGate Compatibility")
struct UpstreamOutputGateCompatibilityTests {

  @Test("Starts closed on silence and stays muted during sub-threshold signal")
  func staysClosedOnSilence() {
    var phase: UInt8 = 0
    var progress: Float = 0
    var silentSamples: Int32 = 0

    for _ in 0..<10 {
      let mult = OutputGate.advance(
        phase: &phase,
        progress: &progress,
        silentSamples: &silentSamples,
        maxPeak: 0,
        frameCount: 256,
        rampSamples: 480,
        silenceHoldSamples: 2400
      )
      #expect(mult == 0)
      #expect(phase == 0)
    }
  }

  @Test("Signal above threshold opens monotonically to unity and closes after hold")
  func fullOpenHoldCloseLifecycle() {
    var phase: UInt8 = 0
    var progress: Float = 0
    var silentSamples: Int32 = 0

    var prev: Float = -1
    for _ in 0..<20 {
      let mult = OutputGate.advance(
        phase: &phase,
        progress: &progress,
        silentSamples: &silentSamples,
        maxPeak: 0.5,
        frameCount: 64,
        rampSamples: 256,
        silenceHoldSamples: 512
      )
      #expect(mult >= prev)
      #expect(mult >= 0 && mult <= 1)
      prev = mult
    }
    #expect(prev == 1.0)
    #expect(phase == 2)

    // Remain silent for silenceHoldSamples (512): holds open while counter accumulates
    let holdFirst = OutputGate.advance(
      phase: &phase,
      progress: &progress,
      silentSamples: &silentSamples,
      maxPeak: 0,
      frameCount: 256,
      rampSamples: 256,
      silenceHoldSamples: 512
    )
    #expect(holdFirst == 1.0)

    // Exceed silenceHoldSamples and advance through closing ramp
    var lastMult = holdFirst
    for _ in 0..<10 {
      lastMult = OutputGate.advance(
        phase: &phase,
        progress: &progress,
        silentSamples: &silentSamples,
        maxPeak: 0,
        frameCount: 128,
        rampSamples: 256,
        silenceHoldSamples: 512
      )
    }
    #expect(lastMult == 0)
    #expect(phase == 0)

    // First non-silent buffer arms opening (phase=1) while returning 0, then ramps cleanly
    let arming = OutputGate.advance(
      phase: &phase,
      progress: &progress,
      silentSamples: &silentSamples,
      maxPeak: 0.25,
      frameCount: 64,
      rampSamples: 256,
      silenceHoldSamples: 512
    )
    #expect(arming == 0)
    #expect(phase == 1)

    let ramped = OutputGate.advance(
      phase: &phase,
      progress: &progress,
      silentSamples: &silentSamples,
      maxPeak: 0.25,
      frameCount: 128,
      rampSamples: 256,
      silenceHoldSamples: 512
    )
    #expect(ramped > 0)
  }

  @Test("Non-silent frame resets accumulated silence counter while open")
  func signalWhileOpenResetsSilenceHold() {
    var phase: UInt8 = 2
    var progress: Float = 1
    var silentSamples: Int32 = 400

    let whileSilent = OutputGate.advance(
      phase: &phase,
      progress: &progress,
      silentSamples: &silentSamples,
      maxPeak: 0,
      frameCount: 64,
      rampSamples: 256,
      silenceHoldSamples: 512
    )
    #expect(whileSilent == 1.0)
    #expect(phase == 2)
    #expect(silentSamples == 464)

    let resetByAudio = OutputGate.advance(
      phase: &phase,
      progress: &progress,
      silentSamples: &silentSamples,
      maxPeak: 0.5,
      frameCount: 128,
      rampSamples: 256,
      silenceHoldSamples: 512
    )
    #expect(resetByAudio == 1.0)
    #expect(phase == 2)
    #expect(silentSamples == 0)
  }
}

// MARK: - ProcessingPipeline & LoudnessEqualizer Compatibility

@Suite("Upstream ProcessingPipeline Compatibility")
struct UpstreamProcessingPipelineCompatibilityTests {

  @Test(
    "sourceIndex maps channels cleanly across common stream layouts",
    arguments: [
      (1, 2, 0, 0),
      (1, 2, 1, nil as Int?),
      (2, 2, 0, 0),
      (2, 2, 1, 1),
      (4, 2, 0, 2),
      (4, 2, 1, 3),
      (2, 1, 0, 1),
      (0, 2, 0, nil as Int?),
      (2, 2, 2, nil as Int?),
    ])
  func sourceIndexMapping(row: (Int, Int, Int, Int?)) {
    #expect(
      AudioPipeline.sourceIndex(inputCount: row.0, outputCount: row.1, outputIndex: row.2) == row.3)
  }

  @Test("Volume ramp converges smoothly toward target gain")
  func volumeRampConverges() {
    let pipeline = AudioPipeline(initialGain: 0)
    let frames = 2048
    let (inBuf, inPtr) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { _, _ in
      0.5
    }
    let (outBuf, outPtr) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { _, _ in
      0
    }
    defer {
      inPtr.deallocate()
      outPtr.deallocate()
    }

    var params = ft_pipeline_default_parameters()
    params.target_gain = 1.0
    params.crossfade_multiplier = 1.0
    params.output_gate_multiplier = 1.0
    params.ramp_coefficient = 0.01

    let status = pipeline.process(input: inBuf, output: outBuf, parameters: params)
    #expect(status == FT_PIPELINE_OK)
    #expect(abs(outPtr[0]) < 0.05)
    #expect(outPtr[(frames - 1) * 2] > 0.45)
    #expect(pipeline.currentGain > 0.9)
  }

  @Test("Ramp never overshoots target (upward)")
  func noOvershootUpward() {
    let frames = 1024
    let target: Float = 0.75
    let result = CompatPipelineSignal.rampOutput(
      initialGain: 0, target: target, rampCoefficient: 0.05, frames: frames)
    for f in 0..<frames {
      let sample = result.samples[f * 2]
      #expect(sample <= target + 1e-7, "Frame \(f): output \(sample) overshoots target \(target)")
      #expect(sample >= 0, "Frame \(f): output should be non-negative")
    }
  }

  @Test("Ramp never overshoots target (downward)")
  func noOvershootDownward() {
    let frames = 1024
    let target: Float = 0.25
    let result = CompatPipelineSignal.rampOutput(
      initialGain: 1, target: target, rampCoefficient: 0.05, frames: frames)
    for f in 0..<frames {
      let sample = result.samples[f * 2]
      #expect(sample >= target - 1e-7, "Frame \(f): output \(sample) undershoots target \(target)")
      #expect(sample <= 1, "Frame \(f): output should not exceed starting volume")
    }
  }

  @Test("Zero target volume: output approaches zero")
  func zeroTargetApproachesZero() {
    let frames = 8192
    let result = CompatPipelineSignal.rampOutput(
      initialGain: 1, target: 0, rampCoefficient: 0.01, frames: frames)
    #expect(result.currentGain < 1e-6)
    #expect(abs(result.samples[(frames - 1) * 2]) < 1e-6)
  }

  @Test("Unmute from zero: ramp recovers to target")
  func unmuteFromZero() {
    let frames = 4096
    let result = CompatPipelineSignal.rampOutput(
      initialGain: 0, target: 0.8, rampCoefficient: 0.01, frames: frames)
    #expect(result.currentGain > 0.79)
    #expect(result.samples[0] > 0)
  }

  @Test("Rapid target reversal: ramp changes direction smoothly")
  func rapidTargetReversal() {
    let pipeline = AudioPipeline(initialGain: 0)
    let frames = 512
    let (inBuf, inPtr) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { _, _ in
      1.0
    }
    let (outBuf, outPtr) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { _, _ in
      0
    }
    defer {
      inPtr.deallocate()
      outPtr.deallocate()
    }

    var params = ft_pipeline_default_parameters()
    params.target_gain = 1.0
    params.crossfade_multiplier = 1.0
    params.output_gate_multiplier = 1.0
    params.ramp_coefficient = 0.01
    #expect(pipeline.process(input: inBuf, output: outBuf, parameters: params) == FT_PIPELINE_OK)
    let volAfterUp = pipeline.currentGain
    #expect(volAfterUp > 0)

    params.target_gain = 0.0
    #expect(pipeline.process(input: inBuf, output: outBuf, parameters: params) == FT_PIPELINE_OK)
    #expect(pipeline.currentGain < volAfterUp)
    #expect(pipeline.currentGain >= 0)
    #expect(!pipeline.currentGain.isNaN)
  }

  @Test("Single-frame buffer: ramp applies exactly once")
  func singleFrameBuffer() {
    let result = CompatPipelineSignal.rampOutput(
      initialGain: 0, target: 1, rampCoefficient: 0.1, frames: 1)
    #expect(abs(result.currentGain - 0.1) < 1e-7)
  }

  @Test("Ramp is symmetric: same coefficient, same speed up and down")
  func rampSymmetry() {
    let frames = 256
    let coeff: Float = 0.02
    let up = CompatPipelineSignal.rampOutput(
      initialGain: 0, target: 1, rampCoefficient: coeff, frames: frames)
    let down = CompatPipelineSignal.rampOutput(
      initialGain: 1, target: 0, rampCoefficient: coeff, frames: frames)
    let distanceUp = 1.0 - up.currentGain
    let distanceDown = down.currentGain
    #expect(
      abs(distanceUp - distanceDown) < 1e-5,
      "Ramp should be symmetric: up distance=\(distanceUp), down distance=\(distanceDown)")
  }

  @Test("Crossfade multiplier scales output correctly")
  func crossfadeMultiplierEffect() {
    let frames = 64
    let result = CompatPipelineSignal.rampOutput(
      initialGain: 1, target: 1, rampCoefficient: 1, frames: frames, crossfadeMultiplier: 0.5)
    for f in 0..<frames {
      #expect(
        abs(result.samples[f * 2] - 0.5) < 1e-7,
        "Crossfade multiplier should halve output at frame \(f)")
    }
  }

  @Test("EQ + SoftLimiter stage ordering keeps hot boosted signal under limiter ceiling")
  func eqBeforeSoftLimiter() {
    let pipeline = AudioPipeline(initialGain: 1.0)
    let eq = EQProcessor(sampleRate: 48000)
    var settings = EQSettings.flat
    settings.bandGains[5] = 12  // +12dB at 1kHz (~4x)
    eq.updateSettings(settings)
    #expect(pipeline.configureEQ(eq) == FT_PIPELINE_OK)

    let frames = 4096
    let omega = 2.0 * Double.pi * 1000.0 / 48000.0
    let (inBuf, inPtr) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { f, _ in
      0.5 * Float(sin(omega * Double(f)))
    }
    let (outBuf, outPtr) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { _, _ in
      0
    }
    defer {
      inPtr.deallocate()
      outPtr.deallocate()
    }

    var params = ft_pipeline_default_parameters()
    params.target_gain = 1.0
    params.crossfade_multiplier = 1.0
    params.output_gate_multiplier = 1.0
    params.ramp_coefficient = 1.0

    #expect(pipeline.process(input: inBuf, output: outBuf, parameters: params) == FT_PIPELINE_OK)
    var maxPeak: Float = 0
    for i in 0..<(frames * 2) {
      maxPeak = max(maxPeak, abs(outPtr[i]))
    }
    #expect(maxPeak <= SoftLimiter.ceiling + 1e-5)
    #expect(maxPeak > SoftLimiter.threshold)
  }

  @Test("Crossfade and OutputGate zero multipliers silence pipeline output")
  func multipliersSilenceOutput() {
    let pipeline = AudioPipeline(initialGain: 1.0)
    let frames = 256
    let (inBuf, inPtr) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { _, _ in
      0.5
    }
    let (outBuf, outPtr) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { _, _ in
      1.0
    }
    defer {
      inPtr.deallocate()
      outPtr.deallocate()
    }

    var params = ft_pipeline_default_parameters()
    params.target_gain = 1.0
    params.ramp_coefficient = 1.0
    params.crossfade_multiplier = 0.0
    params.output_gate_multiplier = 1.0
    #expect(pipeline.process(input: inBuf, output: outBuf, parameters: params) == FT_PIPELINE_OK)
    #expect((0..<(frames * 2)).allSatisfy { outPtr[$0] == 0 })

    params.crossfade_multiplier = 1.0
    params.output_gate_multiplier = 0.0
    #expect(pipeline.process(input: inBuf, output: outBuf, parameters: params) == FT_PIPELINE_OK)
    #expect((0..<(frames * 2)).allSatisfy { outPtr[$0] == 0 })
  }

  @Test(
    "LoudnessEqualizer preserves stereo image, bypasses when disabled, and clears boost when detached"
  )
  func loudnessEqualizerPipelineBehavior() {
    var activeSettings = LoudnessEqualizerSettings()
    activeSettings.enabled = true
    let activeEq = LoudnessEqualizer(settings: activeSettings, sampleRate: 48000)

    let frames = 4096
    let inPtr = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    let outPtr = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer {
      inPtr.deallocate()
      outPtr.deallocate()
    }

    let omega = 2.0 * Double.pi * 1000.0 / 48000.0
    for f in 0..<frames {
      let sample = 0.02 * Float(sin(omega * Double(f)))
      inPtr[f * 2] = sample
      inPtr[f * 2 + 1] = sample
    }

    #expect(
      activeEq.process(input: inPtr, output: outPtr, frameCount: frames, channelCount: 2) == 0)
    let leftRMS = CompatPipelineSignal.rms(
      outPtr, frames: frames, channels: 2, channel: 0, skip: 1024)
    let rightRMS = CompatPipelineSignal.rms(
      outPtr, frames: frames, channels: 2, channel: 1, skip: 1024)
    #expect(abs(leftRMS - rightRMS) < 1e-5)

    // Disabled LoudnessEqualizer passes through bit-exact
    var disabledSettings = LoudnessEqualizerSettings()
    disabledSettings.enabled = false
    let disabledEq = LoudnessEqualizer(settings: disabledSettings, sampleRate: 48000)
    #expect(
      disabledEq.process(input: inPtr, output: outPtr, frameCount: frames, channelCount: 2) == 0)
    let maxDiff = (0..<(frames * 2)).reduce(Float(0)) { max($0, abs(outPtr[$1] - inPtr[$1])) }
    #expect(maxDiff == 0)

    // Detaching active LoudnessEqualizer from AudioPipeline clears any residual boost
    let pipeline = AudioPipeline(initialGain: 1.0)
    #expect(pipeline.configureEqualizer(activeEq) == FT_PIPELINE_OK)
    let (inBuf, ablIn) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { f, _ in
      inPtr[f * 2]
    }
    let (outBuf, ablOut) = CompatPipelineSignal.makeABLBuffer(frames: frames, channels: 2) { _, _ in
      0
    }
    defer {
      ablIn.deallocate()
      ablOut.deallocate()
    }
    var params = ft_pipeline_default_parameters()
    params.target_gain = 1.0
    params.crossfade_multiplier = 1.0
    params.output_gate_multiplier = 1.0
    params.ramp_coefficient = 1.0

    _ = pipeline.process(input: inBuf, output: outBuf, parameters: params)
    #expect(pipeline.configureEqualizer(nil) == FT_PIPELINE_OK)
    #expect(pipeline.process(input: inBuf, output: outBuf, parameters: params) == FT_PIPELINE_OK)
    let detachedDiff = (1024..<(frames * 2)).reduce(Float(0)) {
      max($0, abs(ablOut[$1] - ablIn[$1]))
    }
    #expect(detachedDiff < 1e-5)
  }
}
