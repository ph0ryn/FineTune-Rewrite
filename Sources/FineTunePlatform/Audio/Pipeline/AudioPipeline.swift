import CoreAudio
import NativeAudio

/// Non-RT preparation/probe owner for the production native route. Each instance has its own
/// gain, EQ, AutoEQ and loudness histories. HAL callbacks use its C handle directly, not Swift.
/// Configuration and destruction require a quiescent route and all calls are serialized.
public final class AudioPipeline {
  private let handle: OpaquePointer

  public init(initialGain: Float) {
    guard let handle = ft_pipeline_create(initialGain) else {
      preconditionFailure("Unable to prepare native pipeline (invalid gain or allocation failure)")
    }
    self.handle = handle
  }

  deinit { ft_pipeline_destroy(handle) }

  public var currentGain: Float { ft_pipeline_current_gain(handle) }

  /// Synchronous configuration/probe borrow. The borrower must not retain or destroy the handle.
  /// A live callback owner must separately guarantee that this Swift owner outlives registration.
  public func withNativeHandle<Result>(_ body: (OpaquePointer) -> Result) -> Result {
    withExtendedLifetime(self) { body(handle) }
  }

  @discardableResult
  public func configureEQ(_ source: BiquadProcessor?, autoEQ: Bool = false) -> FTPipelineStatus {
    let stage: UInt32 = autoEQ ? 1 : 0
    guard let source else { return ft_pipeline_configure_biquad(handle, stage, nil) }
    return source.withNativeHandle { ft_pipeline_configure_biquad(handle, stage, $0) }
  }

  @discardableResult
  public func configureEqualizer(_ source: LoudnessEqualizer?) -> FTPipelineStatus {
    guard let source else { return ft_pipeline_configure_equalizer(handle, nil) }
    return source.withNativeHandle { ft_pipeline_configure_equalizer(handle, $0) }
  }

  @discardableResult
  public func configureCompensator(_ source: LoudnessCompensator?) -> FTPipelineStatus {
    guard let source else { return ft_pipeline_configure_compensator(handle, nil) }
    return source.withNativeHandle { ft_pipeline_configure_compensator(handle, $0) }
  }

  /// Float32 ABL adapter for offline rendering/probes, not hardware format discovery/conversion.
  /// Rejects partial samples/frames rather than silently truncating their capacity.
  /// Parameters are mandatory: preparation must supply the intended target gain before the
  /// first buffer, never accidentally replace a prepared attenuated gain with default unity.
  @discardableResult
  public func process(
    input: AudioBuffer, output: AudioBuffer,
    parameters: FTPipelineParameters
  ) -> FTPipelineStatus {
    let sampleSize = UInt32(MemoryLayout<Float>.size)
    guard input.mNumberChannels > 0, output.mNumberChannels > 0,
      input.mDataByteSize % sampleSize == 0, output.mDataByteSize % sampleSize == 0,
      (input.mDataByteSize / sampleSize) % input.mNumberChannels == 0,
      (output.mDataByteSize / sampleSize) % output.mNumberChannels == 0
    else { return FT_PIPELINE_INVALID_ARGUMENT }
    return ft_pipeline_process(
      handle,
      FTPipelineInputBuffer(
        data: input.mData?.assumingMemoryBound(to: Float.self),
        frame_count: input.mDataByteSize / sampleSize / input.mNumberChannels,
        channel_count: input.mNumberChannels),
      FTPipelineOutputBuffer(
        data: output.mData?.assumingMemoryBound(to: Float.self),
        frame_count: output.mDataByteSize / sampleSize / output.mNumberChannels,
        channel_count: output.mNumberChannels),
      parameters)
  }

  /// Compatibility layout policy for preparation. Does not assume that real HAL tap input is
  /// trailing: a live route must derive/validate its channel map from stream metadata first.
  public static func sourceIndex(inputCount: Int, outputCount: Int, outputIndex: Int) -> Int? {
    guard let inputs = UInt32(exactly: inputCount), let outputs = UInt32(exactly: outputCount),
      let index = UInt32(exactly: outputIndex)
    else { preconditionFailure("Invalid pipeline layout counts") }
    let result = ft_pipeline_source_index(inputs, outputs, index)
    return result < 0 ? nil : Int(result)
  }
}
