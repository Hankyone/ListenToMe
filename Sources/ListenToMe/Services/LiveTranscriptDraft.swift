import Foundation

/// Splits a live transcription stream into a stable prefix and a revising tail,
/// similar to Handy's committed/tentative overlay model.
struct LiveTranscriptSnapshot: Equatable, Sendable {
  var committed: String
  var tentative: String

  var display: String { committed + tentative }

  static let empty = LiveTranscriptSnapshot(committed: "", tentative: "")
}

@MainActor
final class LiveTranscriptDraft {
  /// After this quiet period with no new deltas, the whole buffer becomes committed.
  private let stabilizeDelayNanoseconds: UInt64
  private var buffer = ""
  private var committed = ""
  private var stabilizeTask: Task<Void, Never>?
  private var onChange: ((LiveTranscriptSnapshot) -> Void)?

  init(
    stabilizeDelayNanoseconds: UInt64 = 700_000_000,
    onChange: ((LiveTranscriptSnapshot) -> Void)? = nil
  ) {
    self.stabilizeDelayNanoseconds = stabilizeDelayNanoseconds
    self.onChange = onChange
  }

  var snapshot: LiveTranscriptSnapshot {
    if buffer.hasPrefix(committed) {
      return LiveTranscriptSnapshot(
        committed: committed,
        tentative: String(buffer.dropFirst(committed.count))
      )
    }
    // Stream diverged from the frozen prefix — show the live buffer as tentative.
    return LiveTranscriptSnapshot(committed: committed, tentative: buffer)
  }

  func reset() {
    stabilizeTask?.cancel()
    stabilizeTask = nil
    buffer = ""
    committed = ""
    publish()
  }

  func applyDelta(_ text: String) {
    guard !text.isEmpty else { return }
    buffer += text
    scheduleStabilize()
    publish()
  }

  /// Final model transcript replaces the draft entirely (spoken corrections land here).
  func applyCompleted(_ transcript: String) {
    stabilizeTask?.cancel()
    stabilizeTask = nil
    buffer = transcript
    committed = transcript
    publish()
  }

  private func scheduleStabilize() {
    stabilizeTask?.cancel()
    let delay = stabilizeDelayNanoseconds
    stabilizeTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      guard let self, !Task.isCancelled else { return }
      self.committed = self.buffer
      self.publish()
    }
  }

  private func publish() {
    onChange?(snapshot)
  }
}
