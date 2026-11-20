import FineTuneDomain
import FineTunePlatform
import NativeAudio
import Testing

@Suite("Shared non-RT AutoEQ preparation")
struct AutoEQPreparationTests {
  nonisolated struct Golden: Sendable {
    let id: String
    let filters: [AutoEQFilter]?
    let preamp: Float
    let applyPreamp: Bool
    let rate: Double
    let left: [Float]
  }

  nonisolated static let chain: [AutoEQFilter] = [
    .init(type: .lowShelf, frequency: 100, gainDB: -3, q: 0.7071),
    .init(type: .peaking, frequency: 1000, gainDB: 6, q: 1.2),
    .init(type: .highShelf, frequency: 8000, gainDB: 2.5, q: 0.7071),
  ]
  nonisolated static let rawChain: [Float] = [
    0.3125011622905731, -0.026881327852606773, -0.00003547023516148329,
    0.01442598644644022, 0.014893386512994766, 0.010506933555006981,
    0.0066224015317857265, 0.00412445142865181,
  ]
  nonisolated static let goldens: [Golden] = [
    .init(
      id: "absent", filters: nil, preamp: 0, applyPreamp: true, rate: 48000,
      left: [0.25, 0, 0, 0, 0, 0, 0, 0]),
    .init(
      id: "emptyPlus6", filters: [], preamp: 6, applyPreamp: true, rate: 48000,
      left: [0.4988155663013458, 0, 0, 0, 0, 0, 0, 0]),
    .init(
      id: "emptyMinus6", filters: [], preamp: -6, applyPreamp: true, rate: 48000,
      left: [0.12529680132865906, 0, 0, 0, 0, 0, 0, 0]),
    .init(
      id: "emptyPreampOff", filters: [], preamp: 6, applyPreamp: false, rate: 48000,
      left: [0.25, 0, 0, 0, 0, 0, 0, 0]),
    .init(
      id: "chainMinus6at44100", filters: chain, preamp: -6, applyPreamp: true, rate: 44100,
      left: [
        0.1560516357421875, -0.013408749364316463, 0.0015494462568312883,
        0.008440823294222355, 0.007532691583037376, 0.0047696419060230255,
        0.0027974473778158426, 0.0015919515863060951,
      ]),
    .init(
      id: "chainMinus6at48000", filters: chain, preamp: -6, applyPreamp: true, rate: 48000,
      left: [
        0.15662159025669098, -0.01347257848829031, -0.000017777229004423134,
        0.007230120245367289, 0.007464375346899033, 0.00526594091206789,
        0.003319063223898411, 0.0020671223755925894,
      ]),
    .init(
      id: "chainMinus6at96000", filters: chain, preamp: -6, applyPreamp: true, rate: 96000,
      left: [
        0.16091693937778473, -0.010575341992080212, -0.006486537866294384,
        -0.0022065320517867804, 0.0010210600448772311, 0.0029260001610964537,
        0.003723100759088993, 0.0037813950330018997,
      ]),
    .init(
      id: "chainPlus6", filters: chain, preamp: 6, applyPreamp: true, rate: 48000,
      left: [
        0.6235217452049255, -0.05363529920578003, -0.0000707724248059094,
        0.028783626854419708, 0.029716212302446365, 0.020964087918400764,
        0.013213428668677807, 0.008229362778365612,
      ]),
    .init(
      id: "chainPreampOff", filters: chain, preamp: 6, applyPreamp: false, rate: 48000,
      left: rawChain),
    .init(
      id: "chainIgnoredNaNPreamp", filters: chain, preamp: .nan, applyPreamp: false, rate: 48000,
      left: rawChain),
    .init(
      id: "chainDeltaHalfHz", filters: chain, preamp: -6, applyPreamp: true, rate: 48000.5,
      left: [
        0.15662167966365814, -0.013472559861838818, -0.00001798762423277367,
        0.007229938171803951, 0.0074643478728830814, 0.005266000982373953,
        0.0033191312104463577, 0.0020671789534389973,
      ]),
    .init(
      id: "chainDeltaOneHz", filters: chain, preamp: -6, applyPreamp: true, rate: 48001,
      left: [
        0.15662172436714172, -0.013472577556967735, -0.000018143500710721128,
        0.00722980871796608, 0.007464326918125153, 0.0052660442888736725,
        0.0033191866241395473, 0.0020672332029789686,
      ]),
  ]
  nonisolated static let input: [Float] = [0.25, -0.125] + Array(repeating: 0, count: 14)

  @Test("Real C ABI and Swift facade preserve literal pre-refactor signals", arguments: goldens)
  func bothConsumersMatchGolden(_ golden: Golden) throws {
    let native = try #require(ft_biquad_create(2))
    defer { ft_biquad_destroy(native) }
    let swift = AutoEQProcessor(sampleRate: golden.rate)
    swift.setPreampEnabled(golden.applyPreamp)
    if let filters = golden.filters {
      let specs = cFilters(filters)
      let status = specs.withUnsafeBufferPointer {
        ft_biquad_prepare_autoeq(
          native, $0.baseAddress, UInt32($0.count), golden.rate, 48000,
          golden.preamp, golden.applyPreamp)
      }
      #expect(status == FT_BIQUAD_OK)
      swift.updateProfile(
        AutoEQProfile(
          id: golden.id, name: golden.id, source: .imported,
          preampDB: golden.preamp, filters: filters, optimizedSampleRate: 48000))
    } else {
      ft_biquad_set_enabled(native, false)
      swift.updateProfile(nil)
    }
    #expect(ft_biquad_is_enabled(native) == (golden.filters != nil))
    #expect(swift.isEnabled == (golden.filters != nil))
    let expected = golden.left.flatMap { [$0, -$0 / 2] }
    let actual = render(native)
    let actualSwift = render(swift)
    for index in expected.indices {
      #expect(abs(actual[index] - expected[index]) < 1e-7)
      #expect(abs(actualSwift[index] - expected[index]) < 1e-7)
    }
  }

  @Test("Actual callback rate updates and preamp toggles rebuild from the same values")
  func rateAndPreampUpdates() {
    let swift = AutoEQProcessor(sampleRate: 48000)
    swift.updateProfile(
      AutoEQProfile(
        id: "chain", name: "chain", source: .imported,
        preampDB: -6, filters: Self.chain))
    _ = render(swift)
    swift.updateSampleRate(44100)
    let expected = Self.goldens.first { $0.id == "chainMinus6at44100" }!.left
      .flatMap { [$0, -$0 / 2] }
    #expect(render(swift) == expected)
    swift.updateSampleRate(48000)
    swift.setPreampEnabled(false)
    #expect(render(swift) == Self.rawChain.flatMap { [$0, -$0 / 2] })
    swift.updateProfile(nil)
    #expect(!swift.isEnabled)
    #expect(render(swift) == Self.input)
  }

  @Test("Invalid preparation preserves old coefficients, disabled state and warmed history")
  func invalidPreparationIsTransactional() throws {
    let a = try #require(ft_biquad_create(2))
    let b = try #require(ft_biquad_create(2))
    defer {
      ft_biquad_destroy(a)
      ft_biquad_destroy(b)
    }
    let filters = cFilters(Self.chain)
    for handle in [a, b] {
      let status = filters.withUnsafeBufferPointer {
        ft_biquad_prepare_autoeq(handle, $0.baseAddress, UInt32($0.count), 48000, 48000, -6, true)
      }
      #expect(status == FT_BIQUAD_OK)
      _ = render(handle)
    }
    ft_biquad_set_enabled(a, false)
    filters.withUnsafeBufferPointer {
      #expect(
        ft_biquad_prepare_autoeq(a, $0.baseAddress, 11, 48000, 48000, -6, true)
          == FT_BIQUAD_INVALID_ARGUMENT)
      #expect(
        ft_biquad_prepare_autoeq(a, $0.baseAddress, 3, .nan, 48000, -6, true)
          == FT_BIQUAD_INVALID_ARGUMENT)
      #expect(
        ft_biquad_prepare_autoeq(a, $0.baseAddress, 3, 48000, 0, -6, true)
          == FT_BIQUAD_INVALID_ARGUMENT)
      #expect(
        ft_biquad_prepare_autoeq(a, $0.baseAddress, 3, 48000, 48000, .nan, true)
          == FT_BIQUAD_INVALID_ARGUMENT)
      #expect(
        ft_biquad_prepare_autoeq(a, $0.baseAddress, 3, 48000, 48000, .greatestFiniteMagnitude, true)
          == FT_BIQUAD_INVALID_CONFIGURATION)
    }
    #expect(
      ft_biquad_prepare_autoeq(a, nil, 1, 48000, 48000, -6, true) == FT_BIQUAD_INVALID_ARGUMENT)
    #expect(
      ft_biquad_prepare_autoeq(nil, nil, 0, 48000, 48000, 0, true) == FT_BIQUAD_INVALID_ARGUMENT)
    #expect(!ft_biquad_is_enabled(a))
    ft_biquad_set_enabled(a, true)
    #expect(render(a) == render(b))
  }

  private func cFilters(_ filters: [AutoEQFilter]) -> [FTBiquadFilter] {
    filters.map {
      let type: FTBiquadFilterType
      switch $0.type {
      case .peaking: type = FT_BIQUAD_PEAKING
      case .lowShelf: type = FT_BIQUAD_LOW_SHELF
      case .highShelf: type = FT_BIQUAD_HIGH_SHELF
      }
      return FTBiquadFilter(type: type, frequency: $0.frequency, gain_db: $0.gainDB, q: $0.q)
    }
  }

  private func render(_ handle: OpaquePointer) -> [Float] {
    var output = Array(repeating: Float.zero, count: Self.input.count)
    let status = Self.input.withUnsafeBufferPointer { source in
      output.withUnsafeMutableBufferPointer {
        ft_biquad_process(handle, source.baseAddress, $0.baseAddress, 8)
      }
    }
    #expect(status == FT_BIQUAD_OK)
    return output
  }

  private func render(_ processor: AutoEQProcessor) -> [Float] {
    var output = Array(repeating: Float.zero, count: Self.input.count)
    let status = Self.input.withUnsafeBufferPointer { source in
      output.withUnsafeMutableBufferPointer {
        processor.process(input: source.baseAddress!, output: $0.baseAddress!, frameCount: 8)
      }
    }
    #expect(status == FT_BIQUAD_OK)
    return output
  }
}
