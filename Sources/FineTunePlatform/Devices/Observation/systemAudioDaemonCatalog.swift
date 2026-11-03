// SPDX-License-Identifier: GPL-3.0-only
// Compatibility daemon vocabulary derived from FineTune by Ronit Singh.
// Source: FineTune/Audio/Monitors/AudioProcessMonitor.swift, revision
// 2285279d36d3f8115c1c2d4aecd904f1bdf96a51, lines 20-58.
// https://github.com/ronitsingh10/FineTune/blob/2285279d36d3f8115c1c2d4aecd904f1bdf96a51/FineTune/Audio/Monitors/AudioProcessMonitor.swift
// This whole small data file is GPL-3.0-only; other files retain their own licenses.

enum SystemAudioDaemonCatalog {
  private static let bundlePrefixes = [
    "com.apple.siri", "com.apple.Siri", "com.apple.assistant", "com.apple.audio",
    "com.apple.coreaudio", "com.apple.mediaremote", "com.apple.accessibility.heard",
    "com.apple.hearingd", "com.apple.voicebankingd", "com.apple.systemsound",
    "com.apple.FrontBoardServices", "com.apple.frontboard", "com.apple.springboard",
    "com.apple.notificationcenter", "com.apple.NotificationCenter", "com.apple.UserNotifications",
    "com.apple.usernotifications", "com.apple.SpeechRecognitionCore", "com.apple.speech",
    "com.apple.dictation", "com.apple.corespeech", "com.apple.CoreSpeech",
    "com.apple.VoiceControl", "com.apple.voicecontrol",
  ]
  private static let namePrefixes = [
    "systemsoundserverd", "systemsoundserv", "coreaudiod", "audiomxd",
    "speechrecognitiond", "dictationd", "corespeech",
  ]

  static func contains(bundleID: String?, name: String) -> Bool {
    if let bundleID, bundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
    let lower = name.lowercased()
    return namePrefixes.contains { lower.hasPrefix($0) }
  }
}
