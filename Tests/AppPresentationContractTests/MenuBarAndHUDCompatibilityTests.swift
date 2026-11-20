import AppKit
import AudioToolbox
import CoreGraphics
import FineTuneDomain
import FineTunePlatform
import Foundation
import SwiftUI
import Testing

@testable import FineTune

private func makeCompatDevice(
  id: UInt32,
  uid: String,
  name: String,
  transportType: TransportType = .unknown,
  supportsAutoEQ: Bool = false
) -> AudioDevice {
  AudioDevice(
    id: AudioDeviceID(id),
    uid: uid,
    name: name,
    icon: nil,
    supportsAutoEQ: supportsAutoEQ,
    transportType: transportType
  )
}

// MARK: - MenuBar Icon, Device Resolver & Popup Size

@Suite("Upstream MenuBar Icon & Popup Size Compatibility")
@MainActor
struct UpstreamMenuBarPresentationCompatibilityTests {

  @Test("MenuBarIconStyle isSystemSymbol and iconName cover all cases")
  func menuBarIconStylePresentation() {
    #expect(!MenuBarIconStyle.default.isSystemSymbol)
    for style in MenuBarIconStyle.allCases {
      #expect(!style.iconName.isEmpty)
      if style != .default {
        #expect(style.isSystemSymbol)
      }
    }
  }

  @Test("VolumeBucket thresholds cover zero, low, mid, high, and non-finite inputs")
  func volumeBuckets() {
    #expect(VolumeBucket.bucket(for: 0) == .zero)
    #expect(VolumeBucket.bucket(for: 0.009) == .zero)
    #expect(VolumeBucket.bucket(for: .nan) == .zero)
    #expect(VolumeBucket.bucket(for: .infinity) == .zero)
    #expect(VolumeBucket.bucket(for: 0.01) == .low)
    #expect(VolumeBucket.bucket(for: 0.339) == .low)
    #expect(VolumeBucket.bucket(for: 0.34) == .mid)
    #expect(VolumeBucket.bucket(for: 0.669) == .mid)
    #expect(VolumeBucket.bucket(for: 0.67) == .high)
    #expect(VolumeBucket.bucket(for: 1.0) == .high)
  }

  @Test("MenuBarIconState.baseline obeys style, mute, and iconName consistency")
  func iconStateBaselineConsistency() {
    #expect(
      MenuBarIconState.baseline(style: .speaker, volume: 0.5, muted: true) == .speakerMuted)
    #expect(
      MenuBarIconState.baseline(style: .speaker, volume: 0.5, muted: false)
        == .speakerVolume(.mid))
    #expect(
      MenuBarIconState.baseline(style: .default, volume: 0.5, muted: false).image
        == .asset(MenuBarIconStyle.default.iconName))
    #expect(
      MenuBarIconState.baseline(style: .waveform, volume: 0.5, muted: true).image
        == .systemSymbol(MenuBarIconStyle.waveform.iconName))
    #expect(
      MenuBarIconState.baseline(style: .equalizer, volume: 0.5, muted: true).image
        == .systemSymbol(MenuBarIconStyle.equalizer.iconName))
    #expect(
      MenuBarIconState.baseline(style: .device, volume: 0.5, muted: false).image
        == .systemSymbol(MenuBarIconStyle.device.iconName))
    #expect(
      MenuBarIconState.baseline(
        style: .device, volume: 0.5, muted: true, deviceSymbol: "airpodspro")
        == .device(symbol: "airpodspro"))
  }

  @Test(
    "MenuBarDeviceIconResolver follows default device, priority order, overrides, and symbol resolution"
  )
  func deviceIconResolverPrecedence() {
    let spk = makeCompatDevice(id: 1, uid: "spk", name: "MacBook Pro Speakers")
    let pods = makeCompatDevice(id: 2, uid: "pods", name: "AirPods Pro")

    // When defaultDeviceID is absent/unavailable, priority order wins
    let resolvedByPriority = MenuBarDeviceIconResolver.resolveSymbol(
      priorityOrder: ["pods", "spk"],
      outputDevices: [spk, pods],
      defaultDeviceID: AudioDeviceID(0),
      isSymbolResolvable: { _ in true },
      isDeviceAvailable: { _ in true },
      symbolForDefaultID: { _ in MenuBarDeviceIconResolver.fallbackSymbol }
    )
    #expect(resolvedByPriority == "airpodspro")

    // When defaultDeviceID is available, default device wins (including override)
    let withOverride = MenuBarDeviceIconResolver.resolveSymbol(
      priorityOrder: ["pods", "spk"],
      outputDevices: [spk, pods],
      defaultDeviceID: pods.id,
      overrideForUID: { $0 == "pods" ? "homepod" : nil },
      isSymbolResolvable: { _ in true },
      isDeviceAvailable: { _ in true },
      symbolForDefaultID: { _ in MenuBarDeviceIconResolver.fallbackSymbol }
    )
    #expect(withOverride == "homepod")

    // Unresolvable override skips to auto symbol
    let unresolvableOverride = MenuBarDeviceIconResolver.resolveSymbol(
      priorityOrder: ["pods"],
      outputDevices: [pods],
      defaultDeviceID: pods.id,
      overrideForUID: { _ in "invalid.symbol.xyz" },
      isSymbolResolvable: { $0 != "invalid.symbol.xyz" },
      isDeviceAvailable: { _ in true },
      symbolForDefaultID: { _ in MenuBarDeviceIconResolver.fallbackSymbol }
    )
    #expect(unresolvableOverride == "airpodspro")

    // Empty output falls back to fallbackSymbol
    let emptyResolved = MenuBarDeviceIconResolver.resolveSymbol(
      priorityOrder: [],
      outputDevices: [],
      defaultDeviceID: AudioDeviceID(0),
      isSymbolResolvable: { _ in true },
      isDeviceAvailable: { _ in true },
      symbolForDefaultID: { _ in MenuBarDeviceIconResolver.fallbackSymbol }
    )
    #expect(emptyResolved == MenuBarDeviceIconResolver.fallbackSymbol)
  }

  @Test("MenuBarPopupSize dimensions scale strictly upward from compact -> comfortable -> spacious")
  func popupSizeDimensions() {
    let compact = MenuBarPopupSize.compact.dimensions
    let comfortable = MenuBarPopupSize.comfortable.dimensions
    let spacious = MenuBarPopupSize.spacious.dimensions

    #expect(compact == PopupDimensions(width: 470, contentPadding: 12, maxContentHeight: 560))
    #expect(comfortable == PopupDimensions(width: 510, contentPadding: 16, maxContentHeight: 660))
    #expect(spacious == PopupDimensions(width: 560, contentPadding: 20, maxContentHeight: 760))
    #expect(compact.width < comfortable.width && comfortable.width < spacious.width)
    #expect(compact.maxContentHeight < comfortable.maxContentHeight)
    #expect(comfortable.maxContentHeight < spacious.maxContentHeight)
  }
}

// MARK: - Keyboard Navigation & ScrollWheelStep

@Suite("Upstream PopupKeyboardNav & ScrollWheel Compatibility")
@MainActor
struct UpstreamNavigationCompatibilityTests {

  @Test(
    "PopupKeyboardNavModel orders devices before apps, hides rows while editing priority, and does not wrap"
  )
  func keyboardNavOrderAndBounds() {
    let model = PopupKeyboardNavModel()
    let d1 = makeCompatDevice(id: 1, uid: "dev-1", name: "Built-in")
    let d2 = makeCompatDevice(id: 2, uid: "dev-2", name: "USB DAC")
    model.syncOrder(
      activeDevices: [d1, d2], appPersistenceIDs: ["app-1", "app-2"], isEditingPriority: false)

    #expect(
      model.orderedRowIDs == [
        .device(uid: "dev-1"),
        .device(uid: "dev-2"),
        .app(persistenceID: "app-1"),
        .app(persistenceID: "app-2"),
      ])
    #expect(model.defaultFocus(defaultOutputUID: "dev-2") == .device(uid: "dev-2"))
    #expect(model.defaultFocus(defaultOutputUID: "missing") == .device(uid: "dev-1"))

    #expect(model.next(after: nil) == .device(uid: "dev-1"))
    #expect(model.next(after: .device(uid: "dev-2")) == .app(persistenceID: "app-1"))
    #expect(model.next(after: .app(persistenceID: "app-2")) == nil)
    #expect(model.previous(before: .device(uid: "dev-1")) == nil)
    #expect(model.previous(before: .app(persistenceID: "app-1")) == .device(uid: "dev-2"))

    model.syncOrder(activeDevices: [d1, d2], appPersistenceIDs: ["app-1"], isEditingPriority: true)
    #expect(model.orderedRowIDs.isEmpty)
  }

  @Test(
    "ScrollWheelStep ignores momentum tails, handles inversion, clamps bounds, and works with Float"
  )
  func scrollWheelStepContract() {
    var val: Double = 0.5
    ScrollWheelStep.apply(
      deltaY: 10, hasPreciseDeltas: true, isDirectionInverted: false, isMomentumTail: false,
      value: &val, sensitivity: 0.01, in: 0.0...1.0)
    #expect(abs(val - 0.6) < 1e-6)

    ScrollWheelStep.apply(
      deltaY: 10, hasPreciseDeltas: true, isDirectionInverted: true, isMomentumTail: false,
      value: &val, sensitivity: 0.01, in: 0.0...1.0)
    #expect(abs(val - 0.5) < 1e-6)

    ScrollWheelStep.apply(
      deltaY: 100, hasPreciseDeltas: true, isDirectionInverted: false, isMomentumTail: true,
      value: &val, sensitivity: 0.01, in: 0.0...1.0)
    #expect(abs(val - 0.5) < 1e-6)

    ScrollWheelStep.apply(
      deltaY: 200, hasPreciseDeltas: true, isDirectionInverted: false, isMomentumTail: false,
      value: &val, sensitivity: 0.01, in: 0.0...1.0)
    #expect(val == 1.0)

    ScrollWheelStep.apply(
      deltaY: -500, hasPreciseDeltas: true, isDirectionInverted: false, isMomentumTail: false,
      value: &val, sensitivity: 0.01, in: 0.0...1.0)
    #expect(val == 0.0)

    var gain: Float = 0
    ScrollWheelStep.apply(
      deltaY: 8, hasPreciseDeltas: true, isDirectionInverted: false, isMomentumTail: false,
      value: &gain, sensitivity: Float(0.12), in: Float(-12)...Float(12))
    #expect(abs(gain - 0.96) < 1e-4)
  }
}

// MARK: - HUD Thresholds, Popup Parity, Feedback & Positioning

@Suite("Upstream HUD & VolumeFeedback Compatibility")
@MainActor
struct UpstreamHUDPresentationCompatibilityTests {

  @Test("TahoeStyleHUD uses bold row font and ClassicStyleHUD omits percentage label")
  func hudStructureAndThresholds() {
    #expect(TahoeStyleHUD.nameFont == DesignTokens.Typography.rowNameBold)
    #expect(!ClassicStyleHUD.hasPercentageLabel)

    let cases: [(Float, String)] = [
      (0.0, "speaker.fill"),
      (0.004, "speaker.fill"),
      (0.005, "speaker.wave.1.fill"),
      (0.334, "speaker.wave.1.fill"),
      (0.335, "speaker.wave.2.fill"),
      (0.664, "speaker.wave.2.fill"),
      (0.665, "speaker.wave.3.fill"),
      (1.0, "speaker.wave.3.fill"),
    ]
    for (fraction, expected) in cases {
      let tahoe = TahoeStyleHUD(sliderFraction: fraction, mute: false, deviceName: "Test")
      let classic = ClassicStyleHUD(sliderFraction: fraction, mute: false)
      #expect(tahoe.waveIconNameForTest == expected, "fraction=\(fraction)")
      #expect(classic.waveIconNameForTest == expected, "fraction=\(fraction)")
    }
    let mutedClassic = ClassicStyleHUD(sliderFraction: 0.8, mute: true)
    #expect(mutedClassic.waveIconNameForTest == "speaker.fill")
  }

  @Test(
    "DeviceRow slider mapping matches VolumeMapping and VolumeFeedback gain for all control tiers")
  func hudPopupParityAndFeedback() {
    for tier: VolumeControlTier in [.hardware, .ddc, .software] {
      for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let gain = DeviceRow.sliderToVolume(fraction, backend: tier)
        let roundTrip = DeviceRow.volumeToSlider(gain, backend: tier)
        #expect(abs(roundTrip - fraction) < 0.01, "tier=\(tier), fraction=\(fraction)")
        let expectedGain = VolumeMapping.systemGain(forSliderFraction: fraction, tier: tier)
        #expect(abs(gain - expectedGain) < 1e-5)
        let expectedFeedbackGain: Float = tier == .software ? expectedGain : 1
        #expect(
          abs(VolumeFeedback.gain(tier: tier, sliderFraction: fraction) - expectedFeedbackGain)
            < 1e-5)
      }
    }

    #expect(VolumeFeedback.shouldPlay(prefOn: true, shiftHeld: false, optionHeld: false))
    #expect(!VolumeFeedback.shouldPlay(prefOn: false, shiftHeld: false, optionHeld: false))
    #expect(VolumeFeedback.shouldPlay(prefOn: false, shiftHeld: true, optionHeld: false))
    #expect(!VolumeFeedback.shouldPlay(prefOn: true, shiftHeld: true, optionHeld: false))
    #expect(VolumeFeedback.shouldPlay(prefOn: true, shiftHeld: false, optionHeld: true))
  }

  @Test(
    "HUDWindowController.computePosition handles classic, tahoe normal, and tahoe degraded suppression"
  )
  func hudWindowPositioning() {
    let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: 300, height: 72)

    let classic = HUDWindowController.computePosition(
      style: .classic, size: NSSize(width: 200, height: 200), visibleFrame: frame,
      suppressionDegraded: false)
    #expect(classic == NSPoint(x: 620, y: 140))

    let tahoeNormal = HUDWindowController.computePosition(
      style: .tahoe, size: size, visibleFrame: frame, suppressionDegraded: false)
    #expect(tahoeNormal == NSPoint(x: 1132, y: 820))

    let tahoeDegraded = HUDWindowController.computePosition(
      style: .tahoe, size: size, visibleFrame: frame, suppressionDegraded: true)
    #expect(tahoeDegraded == NSPoint(x: 210, y: 820))
  }

  @Test(
    "DeviceInspector shouldShowToggle only allows software override toggle on eligible output devices"
  )
  func deviceDetailToggleVisibility() {
    #expect(DeviceDetailSheet.shouldShowToggle(autoTier: .hardware))
    #expect(DeviceDetailSheet.shouldShowToggle(autoTier: .ddc))
    #expect(!DeviceDetailSheet.shouldShowToggle(autoTier: .software))
    #expect(!DeviceDetailSheet.shouldShowToggle(autoTier: nil))
    #expect(!DeviceDetailSheet.shouldShowToggle(autoTier: .hardware, isInput: true))
    #expect(!DeviceDetailSheet.shouldShowToggle(autoTier: .hardware, allowsVolumeOverride: false))
    #expect(!DeviceDetailSheet.shouldShowToggle(autoTier: .hardware, hasOverrideAction: false))
  }
}
