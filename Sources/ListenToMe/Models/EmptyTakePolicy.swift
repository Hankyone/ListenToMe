import Foundation

/// Empty or aborted takes should not surface as errors. The overlay already
/// shows when the mic is quiet; a banner after a silent tap is noise.
enum EmptyTakePolicy {
  static func shouldShowFailure(
    message: String,
    hasTranscript: Bool,
    hadSpeech: Bool = false
  ) -> Bool {
    if isUserActionableFailure(message) { return true }
    if hasTranscript { return true }
    // "No speech" and friends stay quiet even if the mic picked up room noise.
    if isBenignEmptyTake(message) { return false }
    if hadSpeech { return true }
    return false
  }

  /// Setup, permissions, credentials, and billing are always worth a banner.
  static func isUserActionableFailure(_ message: String) -> Bool {
    isHardFailure(message) || isSetupFailure(message)
  }

  static func isSetupFailure(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("api key")
      || lower.contains("microphone access")
      || lower.contains("language code")
      || lower.contains("accessibility")
      || lower.contains("paste a")
  }

  /// Credential / billing / quota problems are still worth a banner even
  /// when the take had no speech.
  static func isHardFailure(_ message: String) -> Bool {
    let lower = message.lowercased()
    if lower.contains("401")
      || lower.contains("unauthorized")
      || lower.contains("invalid api key")
      || lower.contains("incorrect api key")
    {
      return true
    }
    if lower.contains("429") || lower.contains("rate limit") {
      return true
    }
    if lower.contains("insufficient_quota")
      || lower.contains("quota")
      || lower.contains("billing")
    {
      return true
    }
    return false
  }

  static func isBenignEmptyTake(_ message: String) -> Bool {
    if isUserActionableFailure(message) { return false }
    let lower = message.lowercased()
    return lower.contains("no speech")
      || lower.contains("empty transcript")
      || lower.contains("no audio")
      || lower.contains("audio too short")
      || lower.contains("did not return a final transcript")
      || lower.contains("no transcript came back")
      || lower.contains("transcription did not finish")
      || lower.contains("could not hear")
      || lower.contains("couldn't hear")
      || lower.contains("didn't hear")
      || lower.contains("no sound")
  }
}
