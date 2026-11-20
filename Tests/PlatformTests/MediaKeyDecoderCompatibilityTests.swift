import FineTuneControl
import Foundation
import Testing

@testable import FineTunePlatform

@Suite("Compat: IOKitMediaKeyDecoder — HID bitfield decoding")
struct UpstreamIOKitMediaKeyDecoderTests {
  let decoder = IOKitMediaKeyDecoder()

  @Test("SOUND_UP key-down (data1=2560) decodes to volumeUp(isRepeat:false)")
  func soundUpDown() {
    let result = decoder.decode(data1: 0x0000_0A00)
    #expect(result == .volumeUp(isRepeat: false))
  }

  @Test("SOUND_UP auto-repeat (data1=2561) decodes to volumeUp(isRepeat:true)")
  func soundUpRepeat() {
    let result = decoder.decode(data1: 0x0000_0A01)
    #expect(result == .volumeUp(isRepeat: true))
  }

  @Test("SOUND_UP key-up (data1=2816) decodes to nil (not a key-down)")
  func soundUpKeyUp() {
    let result = decoder.decode(data1: 0x0000_0B00)
    #expect(result == nil)
  }

  @Test("SOUND_DOWN key-down (data1=68096) decodes to volumeDown(isRepeat:false)")
  func soundDownDown() {
    let result = decoder.decode(data1: 0x0001_0A00)
    #expect(result == .volumeDown(isRepeat: false))
  }

  @Test("SOUND_DOWN auto-repeat (data1=68097) decodes to volumeDown(isRepeat:true)")
  func soundDownRepeat() {
    let result = decoder.decode(data1: 0x0001_0A01)
    #expect(result == .volumeDown(isRepeat: true))
  }

  @Test("SOUND_DOWN key-up (data1=68352) decodes to nil")
  func soundDownKeyUp() {
    let result = decoder.decode(data1: 0x0001_0B00)
    #expect(result == nil)
  }

  @Test("MUTE key-down (data1=460288) decodes to muteToggle")
  func muteDown() {
    let result = decoder.decode(data1: 0x0007_0A00)
    #expect(result == .muteToggle)
  }

  @Test("MUTE auto-repeat (data1=460289) decodes to nil (mute ignores repeat)")
  func muteRepeat() {
    let result = decoder.decode(data1: 0x0007_0A01)
    #expect(result == nil)
  }

  @Test("MUTE key-up (data1=460544) decodes to nil")
  func muteKeyUp() {
    let result = decoder.decode(data1: 0x0007_0B00)
    #expect(result == nil)
  }

  @Test("Unknown keyType (BRIGHTNESS, keyType=2, data1=134656) decodes to nil (fail-open)")
  func unknownKeyTypeFailOpen() {
    let result = decoder.decode(data1: 0x0002_0A00)
    #expect(result == nil)
  }

  @Test("MediaKeyEvent.volumeUp(isRepeat:false) equals itself")
  func volumeUpEquatable() {
    #expect(MediaKeyEvent.volumeUp(isRepeat: false) == .volumeUp(isRepeat: false))
    #expect(MediaKeyEvent.volumeUp(isRepeat: false) != .volumeUp(isRepeat: true))
  }

  @Test("MediaKeyEvent.volumeDown and volumeUp are not equal")
  func differentEventsNotEqual() {
    #expect(MediaKeyEvent.volumeDown(isRepeat: false) != .volumeUp(isRepeat: false))
  }
}

@Suite("Compat: IOKitMediaKeyDecoder — fail-open contract")
struct UpstreamMediaKeyDecoderFailOpenTests {
  let decoder = IOKitMediaKeyDecoder()

  @Test("keyType=2 (BRIGHTNESS_UP) key-down decodes to nil")
  func brightnessUpFailOpen() {
    let data1 = (2 << 16) | 0x0A00
    #expect(decoder.decode(data1: data1) == nil)
  }

  @Test("keyType=3 (BRIGHTNESS_DOWN) key-down decodes to nil")
  func brightnessDownFailOpen() {
    let data1 = (3 << 16) | 0x0A00
    #expect(decoder.decode(data1: data1) == nil)
  }

  @Test("keyType=8 (EJECT) key-down decodes to nil")
  func ejectFailOpen() {
    let data1 = (8 << 16) | 0x0A00
    #expect(decoder.decode(data1: data1) == nil)
  }

  @Test("keyType=255 (fabricated unknown) key-down decodes to nil")
  func fabricatedUnknownFailOpen() {
    let data1 = (255 << 16) | 0x0A00
    #expect(decoder.decode(data1: data1) == nil)
  }

  @Test("data1=0 (all zeros) decodes to nil — key-up event for keyType=0")
  func allZeroesFailOpen() {
    #expect(decoder.decode(data1: 0) == nil)
  }

  @Test("data1=-1 (all bits set) decodes to nil — not a recognized down-event")
  func allOnesFailOpen() {
    let result = decoder.decode(data1: -1)
    #expect(result == nil)
  }

  @Test("SOUND_UP key-up (data1=0x00000B00) is always nil regardless of key type")
  func soundUpKeyUpNil() {
    #expect(decoder.decode(data1: 0x0000_0B00) == nil)
  }

  @Test("SOUND_DOWN key-up (data1=0x00010B00) is nil")
  func soundDownKeyUpNil() {
    #expect(decoder.decode(data1: 0x0001_0B00) == nil)
  }

  @Test("MUTE key-up (data1=0x00070B00) is nil")
  func muteKeyUpNil() {
    #expect(decoder.decode(data1: 0x0007_0B00) == nil)
  }

  @Test("MUTE repeat (data1=0x00070A01) returns nil — mute never fires on repeat")
  func muteRepeatNil() {
    #expect(decoder.decode(data1: 0x0007_0A01) == nil)
  }

  @Test("IOKitMediaKeyDecoder satisfies Sendable contract for C callback use")
  func sendableConformance() {
    let _: any MediaKeyEventDecoding & Sendable = IOKitMediaKeyDecoder()
  }
}
