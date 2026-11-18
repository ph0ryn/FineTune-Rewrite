import FineTuneDomain
import Testing

@Suite("Domain: Volume mapping invariants and tier curves")
struct VolumeMappingTests {
  @Test("Software curve maps endpoints and quarter-gain perceptual midpoint accurately")
  func softwareCurveKeyPoints() {
    #expect(VolumeMapping.sliderToGain(0) == 0)
    #expect(VolumeMapping.sliderToGain(0.5) == 0.25)
    #expect(VolumeMapping.sliderToGain(1) == 1)

    #expect(VolumeMapping.gainToSlider(0) == 0)
    #expect(VolumeMapping.gainToSlider(0.25) == 0.5)
    #expect(VolumeMapping.gainToSlider(1) == 1)
  }

  @Test("Out-of-range inputs clamp cleanly to [0, 1]")
  func outOfRangeClamping() {
    for negative in [-100.0, -1.0, -0.0001] {
      #expect(VolumeMapping.sliderToGain(negative) == 0)
      #expect(VolumeMapping.gainToSlider(Float(negative)) == 0)
      #expect(VolumeMapping.systemGain(forSliderFraction: negative, tier: .hardware) == 0)
      #expect(VolumeMapping.systemGain(forSliderFraction: negative, tier: .software) == 0)
      #expect(VolumeMapping.sliderFraction(forSystemGain: Float(negative), tier: .ddc) == 0)
    }
    for overOne in [1.0001, 2.0, 100.0] {
      #expect(VolumeMapping.sliderToGain(overOne) == 1)
      #expect(VolumeMapping.gainToSlider(Float(overOne)) == 1)
      #expect(VolumeMapping.systemGain(forSliderFraction: overOne, tier: .hardware) == 1)
      #expect(VolumeMapping.systemGain(forSliderFraction: overOne, tier: .software) == 1)
      #expect(VolumeMapping.sliderFraction(forSystemGain: Float(overOne), tier: .ddc) == 1)
    }
  }

  @Test("Software slider-gain mapping is monotonic, bounded, and round-trips across 1000 points")
  func softwarePropertyMonotonicityAndRoundTrip() {
    var previousGain: Float = -1
    var previousSlider: Double = -1
    let steps = 1000
    for i in 0...steps {
      let x = Double(i) / Double(steps)
      let gain = VolumeMapping.sliderToGain(x)
      #expect(gain >= 0 && gain <= 1)
      #expect(gain >= previousGain)
      previousGain = gain

      let back = VolumeMapping.gainToSlider(gain)
      #expect(abs(back - x) < 1e-3, "Round-trip mismatch at x=\(x): \(back)")

      let linear = VolumeMapping.gainToSlider(Float(x))
      #expect(linear >= 0 && linear <= 1)
      #expect(linear >= previousSlider)
      previousSlider = linear
    }
  }

  @Test(
    "Hardware and DDC tiers are linear identity on [0, 1], while software is quadratic",
    arguments: [0.0, 0.25, 0.5, 0.75, 1.0])
  func tierCurves(fraction: Double) {
    for tier in [VolumeControlTier.hardware, .ddc] {
      let gain = VolumeMapping.systemGain(forSliderFraction: fraction, tier: tier)
      #expect(abs(Double(gain) - fraction) < 1e-6)
      let roundTrip = VolumeMapping.sliderFraction(forSystemGain: gain, tier: tier)
      #expect(abs(roundTrip - fraction) < 1e-6)
    }

    let swGain = VolumeMapping.systemGain(forSliderFraction: fraction, tier: .software)
    #expect(abs(Double(swGain) - fraction * fraction) < 1e-6)
    let swBack = VolumeMapping.sliderFraction(forSystemGain: swGain, tier: .software)
    #expect(abs(swBack - fraction) < 1e-3)
  }
}
