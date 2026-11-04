// SPDX-License-Identifier: GPL-3.0-only
// Derived from ronitsingh10/FineTune@2285279d36d3f8115c1c2d4aecd904f1bdf96a51.
// Eleven numerical guarantees now run in Tools/DSPTests/LoudnessCompatibilityTests.cpp.
// FineTuneTests/LoudnessEqualizerTests.swift
// Unit tests for the LoudnessEqualizer feature.

import Foundation
import Testing

@testable import FineTune

@Suite("LoudnessEqualizer")
struct LoudnessEqualizerTests {

  // MARK: - LoudnessEqualizerSettings

  @Test("Settings default to approved MVP values")
  func settingsDefaults() {
    let s = LoudnessEqualizerSettings()
    #expect(s.targetLoudnessDb == -12)
    #expect(s.maxBoostDb == 6)
    #expect(s.maxCutDb == 4)
    #expect(s.compressionThresholdOffsetDb == 6)
    #expect(s.compressionRatio == 1.6)
    #expect(s.compressionKneeDb == 8)
    #expect(s.analysisWindowMs == 400)
    #expect(s.analysisHopMs == 100)
    #expect(s.detectorAttackMs == 25)
    #expect(s.detectorReleaseMs == 600)
    #expect(s.gainAttackMs == 250)
    #expect(s.gainReleaseMs == 3000)
    #expect(s.noiseFloorThresholdDb == -40)
    #expect(s.lowLevelMaxBoostDb == 0.5)
    #expect(s.enabled == false)
  }

  // MARK: - LoudnessEqualizer

  @Test("Shared gain preserves left-right ratio for interleaved stereo buffers")
  func loudnessEqualizerPreservesStereoImage() {
    var settings = LoudnessEqualizerSettings()
    settings.enabled = true
    let sampleRate: Float = 48000
    let frameCount = 512
    let channelCount = 2

    let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

    // Input is interleaved production-style stereo: L0,R0,L1,R1,...
    var input = [Float](repeating: 0, count: frameCount * channelCount)
    for frame in 0..<frameCount {
      let base = frame * channelCount
      input[base] = 0.5
      input[base + 1] = 0.25
    }

    var output = [Float](repeating: 0, count: frameCount * channelCount)

    let status = input.withUnsafeMutableBufferPointer { inPtr in
      output.withUnsafeMutableBufferPointer { outPtr in
        eq.process(
          input: inPtr.baseAddress!,
          output: outPtr.baseAddress!,
          frameCount: frameCount,
          channelCount: channelCount
        )
      }
    }
    #expect(status == 0)

    // Extract output channels (interleaved: L0,R0,L1,R1,…)
    let outLeft = stride(from: 0, to: frameCount * channelCount, by: channelCount).map {
      output[$0]
    }
    let outRight = stride(from: 1, to: frameCount * channelCount, by: channelCount).map {
      output[$0]
    }

    // Verify non-zero output (gain was applied)
    let sumLeft = outLeft.map(abs).reduce(0, +)
    let sumRight = outRight.map(abs).reduce(0, +)
    #expect(sumLeft > 0, "Left channel output should be non-zero")
    #expect(sumRight > 0, "Right channel output should be non-zero")

    // Verify L/R ratio is preserved within 1% tolerance
    // Both channels receive the same gain factor, so ratio should stay 2:1
    let ratio = sumLeft / sumRight
    #expect(
      abs(ratio - 2.0) < 0.02,
      "Left/right ratio should remain 2:1 after loudness processing; got \(ratio)")
  }

  @Test("Disabled equalizer is unity passthrough for interleaved stereo buffers")
  func disabledEqualizerPassesThroughUnchanged() {
    let settings = LoudnessEqualizerSettings()
    let sampleRate: Float = 48000
    let frameCount = 256
    let channelCount = 2

    let eq = LoudnessEqualizer(settings: settings, sampleRate: sampleRate)

    var input = [Float](repeating: 0, count: frameCount * channelCount)
    for frame in 0..<frameCount {
      let base = frame * channelCount
      input[base] = Float(frame) / Float(frameCount)
      input[base + 1] = -0.5 * Float(frame) / Float(frameCount)
    }
    var output = [Float](repeating: 0, count: frameCount * channelCount)

    let status = input.withUnsafeMutableBufferPointer { inPtr in
      output.withUnsafeMutableBufferPointer { outPtr in
        eq.process(
          input: inPtr.baseAddress!,
          output: outPtr.baseAddress!,
          frameCount: frameCount,
          channelCount: channelCount
        )
      }
    }
    #expect(status == 0)

    for index in 0..<input.count {
      #expect(
        abs(output[index] - input[index]) < 1e-7,
        "Disabled equalizer should pass through sample \(index) unchanged; expected \(input[index]), got \(output[index])"
      )
    }
  }

  @Test("Disabling after active gain riding restores immediate unity passthrough")
  func disablingAfterProcessingClearsResidualGain() {
    var enabledSettings = LoudnessEqualizerSettings()
    enabledSettings.enabled = true

    let sampleRate: Float = 48000
    let frameCount = 2048
    let channelCount = 2
    let enabledEq = LoudnessEqualizer(settings: enabledSettings, sampleRate: sampleRate)

    var loudInput = [Float](repeating: 0, count: frameCount * channelCount)
    for frame in 0..<frameCount {
      let base = frame * channelCount
      loudInput[base] = 0.95
      loudInput[base + 1] = 0.95
    }
    var loudOutput = [Float](repeating: 0, count: frameCount * channelCount)

    let loudStatus = loudInput.withUnsafeMutableBufferPointer { inPtr in
      loudOutput.withUnsafeMutableBufferPointer { outPtr in
        enabledEq.process(
          input: inPtr.baseAddress!,
          output: outPtr.baseAddress!,
          frameCount: frameCount,
          channelCount: channelCount
        )
      }
    }
    #expect(loudStatus == 0)

    // LoudnessEqualizer is immutable — create a new disabled instance
    // (matches the atomic swap pattern used in production)
    var disabledSettings = LoudnessEqualizerSettings()
    disabledSettings.enabled = false
    let disabledEq = LoudnessEqualizer(settings: disabledSettings, sampleRate: sampleRate)

    var quietInput = [Float](repeating: 0, count: frameCount * channelCount)
    for frame in 0..<frameCount {
      let base = frame * channelCount
      quietInput[base] = 0.2
      quietInput[base + 1] = -0.1
    }
    var quietOutput = [Float](repeating: 0, count: frameCount * channelCount)

    let quietStatus = quietInput.withUnsafeMutableBufferPointer { inPtr in
      quietOutput.withUnsafeMutableBufferPointer { outPtr in
        disabledEq.process(
          input: inPtr.baseAddress!,
          output: outPtr.baseAddress!,
          frameCount: frameCount,
          channelCount: channelCount
        )
      }
    }
    #expect(quietStatus == 0)

    for index in 0..<quietInput.count {
      #expect(
        abs(quietOutput[index] - quietInput[index]) < 1e-6,
        "Disabling should clear residual gain immediately at sample \(index); expected \(quietInput[index]), got \(quietOutput[index])"
      )
    }
  }
}
