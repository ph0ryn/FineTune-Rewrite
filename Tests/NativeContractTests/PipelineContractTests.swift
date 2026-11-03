// Independently authored tests for the new NativeAudio boundary (MIT).
import NativeAudio
import Testing

@Suite("Native pipeline ownership and validation")
struct PipelineContractTests {
  @Test("Initial gain is applied to the first frame and route state is independent")
  func initialGainAndIndependentRoutes() throws {
    let a = try #require(ft_pipeline_create(0.25))
    let b = try #require(ft_pipeline_create(0.75))
    defer {
      ft_pipeline_destroy(a)
      ft_pipeline_destroy(b)
    }
    let input: [Float] = [0.5, -0.5]
    var output = [Float](repeating: 0, count: 2)
    var parameters = ft_pipeline_default_parameters()
    parameters.target_gain = 0.25
    input.withUnsafeBufferPointer { source in
      output.withUnsafeMutableBufferPointer { destination in
        let status = ft_pipeline_process(
          a,
          FTPipelineInputBuffer(data: source.baseAddress, frame_count: 1, channel_count: 2),
          FTPipelineOutputBuffer(data: destination.baseAddress, frame_count: 1, channel_count: 2),
          parameters)
        #expect(status == FT_PIPELINE_OK)
      }
    }
    #expect(output == [0.125, -0.125])
    #expect(ft_pipeline_current_gain(a) == 0.25)
    #expect(ft_pipeline_current_gain(b) == 0.75)
  }

  @Test("Invalid input is rejected without writes or state mutation")
  func invalidInputDoesNotMutate() throws {
    let route = try #require(ft_pipeline_create(0.5))
    defer { ft_pipeline_destroy(route) }
    var output: [Float] = [0.321, -0.123]
    output.withUnsafeMutableBufferPointer { destination in
      let status = ft_pipeline_process(
        route, FTPipelineInputBuffer(data: nil, frame_count: 1, channel_count: 2),
        FTPipelineOutputBuffer(data: destination.baseAddress, frame_count: 1, channel_count: 2),
        ft_pipeline_default_parameters())
      #expect(status == FT_PIPELINE_INVALID_ARGUMENT)
    }
    #expect(output == [0.321, -0.123])
    #expect(ft_pipeline_current_gain(route) == 0.5)
  }

  @Test("Configuration errors are explicit and destruction accepts null")
  func invalidConfigurationAndNullDestruction() {
    #expect(ft_pipeline_create(.nan) == nil)
    #expect(ft_pipeline_create(-0.1) == nil)
    ft_pipeline_destroy(nil)
  }

  @Test(
    "Two routes copy distinct EQ configurations, preserve shared input and outlive source handles")
  func sharedReadOnlyInputHasIndependentEQ() throws {
    let a = try #require(ft_pipeline_create(1))
    let b = try #require(ft_pipeline_create(1))
    defer {
      ft_pipeline_destroy(a)
      ft_pipeline_destroy(b)
    }
    let source = try #require(ft_biquad_create(2))
    var coefficients: [Double] = [0.5, 0, 0, 0, 0]
    #expect(
      coefficients.withUnsafeBufferPointer {
        ft_biquad_replace_coefficients(source, $0.baseAddress, 1)
      } == FT_BIQUAD_OK)
    ft_biquad_set_enabled(source, true)
    #expect(ft_pipeline_configure_biquad(a, 0, source) == FT_PIPELINE_OK)
    coefficients[0] = 0.25
    #expect(
      coefficients.withUnsafeBufferPointer {
        ft_biquad_replace_coefficients(source, $0.baseAddress, 1)
      } == FT_BIQUAD_OK)
    #expect(ft_pipeline_configure_biquad(b, 0, source) == FT_PIPELINE_OK)
    // No source pointer is retained by either route.
    ft_biquad_destroy(source)
    let input: [Float] = [0.8, -0.8, 0.4, -0.4]
    let first = render(a, input: input)
    let second = render(b, input: input)
    #expect(first.status == FT_PIPELINE_OK && second.status == FT_PIPELINE_OK)
    #expect(first.output == [0.4, -0.4, 0.2, -0.2])
    #expect(second.output == [0.2, -0.2, 0.1, -0.1])
    // Compare scalar constants, not a COW alias of the same backing array.
    #expect(input[0] == 0.8 && input[1] == -0.8 && input[2] == 0.4 && input[3] == -0.4)
  }

  @Test("Reconfiguring route A does not reset or mutate route B filter history")
  func routeReconfigurationPreservesOtherHistory() throws {
    let a = try #require(ft_pipeline_create(1))
    let b = try #require(ft_pipeline_create(1))
    let reference = try #require(ft_pipeline_create(1))
    let source = try #require(ft_biquad_create(2))
    defer {
      ft_pipeline_destroy(a)
      ft_pipeline_destroy(b)
      ft_pipeline_destroy(reference)
      ft_biquad_destroy(source)
    }
    let coefficients: [Double] = [0.1, 0, 0, -0.5, 0]
    #expect(
      coefficients.withUnsafeBufferPointer {
        ft_biquad_replace_coefficients(source, $0.baseAddress, 1)
      } == FT_BIQUAD_OK)
    ft_biquad_set_enabled(source, true)
    for route in [a, b, reference] {
      #expect(ft_pipeline_configure_biquad(route, 0, source) == FT_PIPELINE_OK)
      #expect(render(route, input: [1, 1]).status == FT_PIPELINE_OK)
    }
    #expect(ft_pipeline_configure_biquad(a, 0, nil) == FT_PIPELINE_OK)
    let bTail = render(b, input: [0, 0, 0, 0])
    let referenceTail = render(reference, input: [0, 0, 0, 0])
    #expect(bTail.status == FT_PIPELINE_OK && referenceTail.status == FT_PIPELINE_OK)
    #expect(bTail.output == referenceTail.output)
    #expect(bTail.output[0] > 0, "B must retain its nonzero impulse tail")
    #expect(render(a, input: [0, 0, 0, 0]).output == [0, 0, 0, 0])
  }

  @Test("Invalid channel counts and parameters leave the destination and gain unchanged")
  func validationIsTransactional() throws {
    let route = try #require(ft_pipeline_create(0.5))
    defer { ft_pipeline_destroy(route) }
    let input: [Float] = [0.4, 0.4]
    for channels: UInt32 in [0, 9] {
      var output: [Float] = [0.33, -0.33]
      input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
          #expect(
            ft_pipeline_process(
              route,
              FTPipelineInputBuffer(
                data: source.baseAddress, frame_count: 1, channel_count: channels),
              FTPipelineOutputBuffer(
                data: destination.baseAddress, frame_count: 1, channel_count: 2),
              ft_pipeline_default_parameters()) == FT_PIPELINE_INVALID_ARGUMENT)
        }
      }
      #expect(output == [0.33, -0.33])
      #expect(ft_pipeline_current_gain(route) == 0.5)
    }
    var invalid = ft_pipeline_default_parameters()
    invalid.ramp_coefficient = .nan
    let result = render(route, input: input, parameters: invalid, fill: 0.33)
    #expect(result.status == FT_PIPELINE_INVALID_ARGUMENT)
    #expect(result.output == [0.33, 0.33])
    #expect(ft_pipeline_current_gain(route) == 0.5)
    #expect(ft_pipeline_configure_biquad(route, 2, nil) == FT_PIPELINE_INVALID_ARGUMENT)
  }

  @Test("Partial overlap is rejected before modifying either range")
  func partialOverlapIsRejected() throws {
    let route = try #require(ft_pipeline_create(1))
    defer { ft_pipeline_destroy(route) }
    var samples: [Float] = [0.1, 0.2, 0.3]
    samples.withUnsafeMutableBufferPointer { buffer in
      #expect(
        ft_pipeline_process(
          route, FTPipelineInputBuffer(data: buffer.baseAddress, frame_count: 1, channel_count: 2),
          FTPipelineOutputBuffer(
            data: buffer.baseAddress!.advanced(by: 1), frame_count: 1, channel_count: 2),
          ft_pipeline_default_parameters()) == FT_PIPELINE_INVALID_ARGUMENT)
    }
    #expect(samples == [0.1, 0.2, 0.3])
  }

  @Test("Zero input frames explicitly silence all output without advancing gain")
  func emptyInputSilencesCapacity() throws {
    let route = try #require(ft_pipeline_create(0.25))
    defer { ft_pipeline_destroy(route) }
    let result = render(route, input: [], outputFrames: 3, fill: 0.4)
    #expect(result.status == FT_PIPELINE_OK)
    #expect(result.output == [Float](repeating: 0, count: 6))
    #expect(ft_pipeline_current_gain(route) == 0.25)
    #expect(
      ft_pipeline_process(
        route, FTPipelineInputBuffer(data: nil, frame_count: 0, channel_count: 2),
        FTPipelineOutputBuffer(data: nil, frame_count: 0, channel_count: 2),
        ft_pipeline_default_parameters()) == FT_PIPELINE_OK)
  }

  @Test("Non-finite signals mute explicitly and the next clean block recovers")
  func nonfiniteSignalAndRecovery() throws {
    let route = try #require(ft_pipeline_create(1))
    defer { ft_pipeline_destroy(route) }
    let failed = render(route, input: [.nan, 0.4])
    #expect(failed.status == FT_PIPELINE_NONFINITE_SIGNAL)
    #expect(failed.output == [0, 0])
    let recovered = render(route, input: [0.4, -0.4])
    #expect(recovered.status == FT_PIPELINE_OK)
    #expect(recovered.output == [0.4, -0.4])
  }

  @Test("Exact in-place mapping and large blocks use the same native route")
  func inPlaceAndLargeBlock() throws {
    let route = try #require(ft_pipeline_create(0.5))
    defer { ft_pipeline_destroy(route) }
    var samples = [Float](repeating: 0.4, count: 65536 * 2)
    var parameters = ft_pipeline_default_parameters()
    parameters.target_gain = 0.5
    samples.withUnsafeMutableBufferPointer { buffer in
      #expect(
        ft_pipeline_process(
          route,
          FTPipelineInputBuffer(data: buffer.baseAddress, frame_count: 65536, channel_count: 2),
          FTPipelineOutputBuffer(data: buffer.baseAddress, frame_count: 65536, channel_count: 2),
          parameters) == FT_PIPELINE_OK)
    }
    #expect(samples.allSatisfy { $0 == 0.2 })
  }

  @Test("Malformed gate and crossfade updates preserve their states")
  func transitionValidation() {
    var gate = FTOutputGateState(phase: 1, progress: 0.25, silent_frames: 42)
    var multiplier: Float = 0.123
    #expect(
      ft_output_gate_advance(&gate, 0.5, 32, 0, 9600, &multiplier) == FT_PIPELINE_INVALID_ARGUMENT)
    #expect(gate.phase == 1 && gate.progress == 0.25 && gate.silent_frames == 42)
    #expect(multiplier == 0.123)
    var crossfade = ft_crossfade_initial_state()
    #expect(ft_crossfade_begin_warmup(&crossfade) == FT_PIPELINE_OK)
    #expect(ft_crossfade_advance(&crossfade, -1) == FT_PIPELINE_INVALID_ARGUMENT)
    #expect(crossfade.phase == 1 && crossfade.progress == 0)
    #expect(crossfade.secondary_samples_processed == 0)
  }
}

private func render(
  _ route: OpaquePointer, input: [Float], outputFrames: Int? = nil,
  parameters: FTPipelineParameters = ft_pipeline_default_parameters(), fill: Float = 0
) -> (output: [Float], status: FTPipelineStatus) {
  let frames = outputFrames ?? input.count / 2
  var output = [Float](repeating: fill, count: frames * 2)
  let status = input.withUnsafeBufferPointer { source in
    output.withUnsafeMutableBufferPointer { destination in
      ft_pipeline_process(
        route,
        FTPipelineInputBuffer(
          data: source.baseAddress, frame_count: UInt32(input.count / 2), channel_count: 2),
        FTPipelineOutputBuffer(
          data: destination.baseAddress, frame_count: UInt32(frames), channel_count: 2),
        parameters)
    }
  }
  return (output, status)
}
