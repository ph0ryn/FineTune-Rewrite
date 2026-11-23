import NativeAudio

/// Control/probe adapter to the native pure output-gate transition. HAL code calls the C API.
public enum OutputGate {
  public static func advance(
    phase: inout UInt8, progress: inout Float, silentSamples: inout Int32,
    maxPeak: Float, frameCount: Int, rampSamples: Float, silenceHoldSamples: Int32
  ) -> Float {
    guard let frames = UInt32(exactly: frameCount),
      let hold = UInt32(exactly: silenceHoldSamples)
    else { preconditionFailure("Invalid gate frame count") }
    var state = FTOutputGateState(
      phase: UInt32(phase), progress: progress, silent_frames: Int64(silentSamples))
    var multiplier: Float = 0
    let status = ft_output_gate_advance(&state, maxPeak, frames, rampSamples, hold, &multiplier)
    precondition(status == FT_PIPELINE_OK, "Invalid output-gate transition")
    guard let silent = Int32(exactly: state.silent_frames) else {
      preconditionFailure("Output-gate counter exceeded adapter range")
    }
    guard let nextPhase = UInt8(exactly: state.phase) else {
      preconditionFailure("Output-gate phase exceeded adapter range")
    }
    phase = nextPhase
    progress = state.progress
    silentSamples = silent
    return multiplier
  }
}
