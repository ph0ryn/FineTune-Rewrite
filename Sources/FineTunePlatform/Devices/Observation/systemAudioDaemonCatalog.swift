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
