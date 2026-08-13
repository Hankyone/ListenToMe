import Foundation

/// What a dictation shortcut press should do. Extra / repeated activations
/// must not brick the session: idle always starts, live always stops.
enum HotkeyTakeAction: Equatable {
  case start
  case stop
  case continueTake
}

enum HotkeyTakePolicy {
  static func actionForPress(
    phase: RecordingPhase,
    pendingReleaseStop: Bool
  ) -> HotkeyTakeAction {
    if pendingReleaseStop {
      switch phase {
      case .recording, .connecting:
        return .continueTake
      default:
        break
      }
    }

    switch phase {
    case .idle, .delivered, .failed:
      return .start
    case .recording, .connecting, .finishing:
      return .stop
    }
  }
}

/// How `requestStop` should tear down a take. A live stop must never no-op
/// just because the websocket isn't up yet — that left the overlay stuck.
enum RecordingStopDecision: Equatable {
  /// Websocket is streaming — commit and transcribe.
  case finishLive
  /// Mic is already writing; let `start()` call `stop()` once the socket is up.
  case finishAfterConnect
  /// Nothing to keep — drop the half-open take and hide the overlay.
  case abort
  /// Hung or in-flight finish — recover so the plate can go away.
  case recoverFinishing
  /// `start()` hasn't painted `.recording` yet; don't let it begin.
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
