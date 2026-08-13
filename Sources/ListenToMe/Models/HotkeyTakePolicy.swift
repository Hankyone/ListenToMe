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
  /// Released before the hold threshold — listening until the next click.
  case tap
  /// Crossed the hold threshold — release always ends the take.
  case hold
}

enum DictationReleaseAction: Equatable {
  case ignore
  case becomeTap
  case endHold
}

/// Click vs hold, plus when a take is too short to bother transcribing.
enum DictationGesturePolicy {
  /// Still down past this → hold. Short enough that a spoken word on PTT
  /// is a hold, not a tap that leaves the plate up.
  static let holdThreshold: TimeInterval = 0.22
  /// After a tap-start, a second click this soon is "I meant to use it",
  /// not "I'm done".
  static let tapRetriggerGrace: TimeInterval = 0.40
  /// After a hold ends, ignore bounce presses so we don't start a new take.
  static let holdEndIgnoreWindow: TimeInterval = 0.16
  /// Shorter than this: dismiss, skip the transcription pipeline.
  static let minTranscribeDuration: TimeInterval = 0.20

  static func pressAction(
    phase: RecordingPhase,
    liveKind: DictationLiveKind,
    liveElapsed: TimeInterval,
    keyPhysicallyDown: Bool,
    secondsSinceHoldEnded: TimeInterval?
  ) -> HotkeyTakeAction {
    if let elapsed = secondsSinceHoldEnded, elapsed < holdEndIgnoreWindow {
      return .ignore
    }

    switch phase {
    case .idle, .delivered, .failed:
      return .start
    case .finishing:
      return .stop
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
    alreadyRequestedStop: Bool
  ) -> RecordingStopDecision {
    switch phase {
    case .idle, .delivered, .failed:
      return .markStopBeforeStart
    case .finishing:
      return .recoverFinishing
    case .connecting, .recording:
      if hasAudioSendTask {
        return .finishLive
      }
      if isMicRecording && !alreadyRequestedStop {
        return .finishAfterConnect
      }
      return .abort
    }
  }
}
