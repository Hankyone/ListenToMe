import Foundation

/// A provider "completed" event is a live snapshot, not the end of the take.
/// Gemini can emit a final transcript while you are still talking, including
/// right before a ten-minute connection rollover. Paste only after stop.
enum LiveTakeCompletionPolicy {
  static func shouldPasteNow(phase: RecordingPhase) -> Bool {
    phase == .finishing
  }
}
