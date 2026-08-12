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
    case .recording, .connecting:
      return .stop
    case .finishing:
      return .start
    }
  }
}
