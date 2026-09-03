import Foundation

/// What a dictation shortcut press should do.
enum HotkeyTakeAction: Equatable {
  case start
  case stop
  case ignore
}

enum DictationLiveKind: Equatable {
  /// Key is down; click vs hold not decided yet.
  case unclassified
  /// Released before the hold threshold  -  listening until the next click.
  case tap
  /// Crossed the hold threshold  -  release always ends the take.
  case hold
}

enum DictationReleaseAction: Equatable {
  case ignore
  case becomeTap
  case endHold
}

/// Click vs hold, plus when a take is too short to bother transcribing.
///
/// Press (key down):
/// - Idle / delivered / failed / finishing → start. Finishing means the last
///   take is still pasting; a real press starts the next take anyway.
/// - Recording + hold/unclassified while the key is still down → ignore
///   (Carbon repeat, not a new click).
/// - Recording + tap within tapRetriggerGrace → ignore (bounce after a click).
/// - Recording otherwise → stop (second click ends hands-free).
/// - Ghost keyDown after a hold with the key already up → ignore.
///
/// Release (key up), if this press started the take and Space-lock is off:
/// - Hold, or past holdThreshold → end the take.
/// - Short press with tap enabled → stay listening (hands-free).
/// - Hold-only mode → end even if the press was short.
enum DictationGesturePolicy {
  /// Still down past this → hold. Short enough that a spoken word on PTT
  /// is a hold, not a tap that leaves the plate up.
  static let holdThreshold: TimeInterval = 0.22
  /// After a tap-start, a second click this soon is "I meant to use it",
  /// not "I'm done".
  static let tapRetriggerGrace: TimeInterval = 0.40
  /// After a hold ends, ignore a ghost keyDown only when the key is already up.
  static let holdEndIgnoreWindow: TimeInterval = 0.16
  /// Shorter than this: dismiss, skip the transcription pipeline.
  static let minTranscribeDuration: TimeInterval = 0.20
  /// After key-up, keep the mic open so the last syllable and a bit of
  /// trailing silence still reach the transcriber.
  static let releaseTail: TimeInterval = 0.40
  /// A take that never ends  -  a missed key-up, a wedged finish  -  must
  /// not hold the app and the hotkey hostage. This long, force it idle.
  static let recordingWatchdogSeconds: TimeInterval = 600
  static var releaseTailNanoseconds: UInt64 {
    UInt64(releaseTail * 1_000_000_000)
  }

  static func pressAction(
    phase: RecordingPhase,
    liveKind: DictationLiveKind,
    liveElapsed: TimeInterval,
    keyPhysicallyDown: Bool,
    secondsSinceHoldEnded: TimeInterval?
  ) -> HotkeyTakeAction {
    if let elapsed = secondsSinceHoldEnded,
      elapsed < holdEndIgnoreWindow,
      !keyPhysicallyDown
    {
      return .ignore
    }

    switch phase {
    case .idle, .delivered, .failed, .finishing:
      return .start
    case .connecting, .recording:
      break
    }

    if liveKind == .hold, keyPhysicallyDown {
      return .ignore
    }
    if liveKind == .unclassified, keyPhysicallyDown {
      return .ignore
    }
    if liveKind == .tap, liveElapsed < tapRetriggerGrace {
      return .ignore
    }
    return .stop
  }

  static func releaseAction(
    startedThisPress: Bool,
    liveKind: DictationLiveKind,
    holdEnabled: Bool,
    tapEnabled: Bool,
    elapsed: TimeInterval,
    isLocked: Bool
  ) -> DictationReleaseAction {
    guard startedThisPress, !isLocked else { return .ignore }

    switch liveKind {
    case .tap:
      return .ignore
    case .hold:
      return holdEnabled ? .endHold : .ignore
    case .unclassified:
      if holdEnabled, elapsed >= holdThreshold {
        return .endHold
      }
      if tapEnabled {
        return .becomeTap
      }
      if holdEnabled {
        return .endHold
      }
      return .ignore
    }
  }

  static func shouldSkipTranscription(elapsed: TimeInterval) -> Bool {
    elapsed < minTranscribeDuration
  }
}

/// How `requestStop` should tear down a take that is worth transcribing.
enum RecordingStopDecision: Equatable {
  case finishLive
  case finishAfterConnect
  case abort
  case recoverFinishing
  case markStopBeforeStart
}

enum RecordingStopPolicy {
  static func decision(
    phase: RecordingPhase,
    hasAudioSendTask: Bool,
    isMicRecording: Bool,
    alreadyRequestedStop: Bool,
    usesBatchTranscription: Bool = false
  ) -> RecordingStopDecision {
    switch phase {
    case .idle, .delivered, .failed:
      return .markStopBeforeStart
    case .finishing:
      return .recoverFinishing
    case .connecting:
      // A normal PTT release may arrive during the fixed media lead or while
      // the warm microphone is being promoted. Let startup finish once, then
      // stop the valid take. A second stop is an explicit abort escape hatch.
      return alreadyRequestedStop ? .abort : .finishAfterConnect
    case .recording:
      if hasAudioSendTask || (usesBatchTranscription && isMicRecording) {
        return .finishLive
      }
      if isMicRecording && !alreadyRequestedStop {
        return .finishAfterConnect
      }
      return .abort
    }
  }
}
