import Foundation
import os

/// Monotonic marks for one dictation take. First write to a name wins so
/// "time to first PCM / first text" stays honest.
final class TakeLatencyTrace: @unchecked Sendable {
  private let lock = NSLock()
  private let origin: ContinuousClock.Instant
  private var marks: [(name: String, ms: Int)] = []
  private var notes: [String: String] = [:]
  private var finished = false

  init(clock: ContinuousClock = ContinuousClock()) {
    origin = clock.now
  }

  func mark(_ name: String) {
    let ms = Int(origin.duration(to: ContinuousClock.now) / .milliseconds(1))
    lock.lock()
    defer { lock.unlock() }
    if finished { return }
    if marks.contains(where: { $0.name == name }) { return }
    marks.append((name, max(0, ms)))
  }

  func note(_ key: String, _ value: String) {
    lock.lock()
    notes[key] = value
    lock.unlock()
  }

  func snapshot() -> TakeLatencySnapshot {
    lock.lock()
    defer { lock.unlock() }
    return TakeLatencySnapshot(marks: marks, notes: notes)
  }

  func finish() -> TakeLatencySnapshot {
    lock.lock()
    finished = true
    let shot = TakeLatencySnapshot(marks: marks, notes: notes)
    lock.unlock()
    return shot
  }
}

struct TakeLatencySnapshot: Equatable, Sendable {
  var marks: [(name: String, ms: Int)]
  var notes: [String: String]

  static func == (lhs: TakeLatencySnapshot, rhs: TakeLatencySnapshot) -> Bool {
    lhs.marks.map { "\($0.name):\($0.ms)" } == rhs.marks.map { "\($0.name):\($0.ms)" }
      && lhs.notes == rhs.notes
  }

  var millisecondsByName: [String: Int] {
    Dictionary(uniqueKeysWithValues: marks.map { ($0.name, $0.ms) })
  }

  var line: String {
    let body = marks.map { "\($0.name)=\($0.ms)" }.joined(separator: " ")
    let extra = notes
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    if extra.isEmpty { return body }
    return extra + " " + body
  }
}

enum LatencyLog {
  private static let logger = Logger(
    subsystem: "ca.hankyone.ListenToMe",
    category: "latency"
  )

  static func write(_ snapshot: TakeLatencySnapshot) {
    logger.info("\(snapshot.line, privacy: .public)")
    appendJSONL(snapshot)
  }

  static var logURL: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return base
      .appendingPathComponent("ListenToMe", isDirectory: true)
      .appendingPathComponent("latency.jsonl")
  }

  private static func appendJSONL(_ snapshot: TakeLatencySnapshot) {
    var object: [String: Any] = [
      "at": ISO8601DateFormatter().string(from: Date()),
      "ms": snapshot.millisecondsByName,
    ]
    if !snapshot.notes.isEmpty {
      object["notes"] = snapshot.notes
    }
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object),
      var line = String(data: data, encoding: .utf8)
    else {
      return
    }
    line.append("\n")
    let url = logURL
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: url.path) {
        if let handle = try? FileHandle(forWritingTo: url) {
          defer { try? handle.close() }
          try handle.seekToEnd()
          try handle.write(contentsOf: Data(line.utf8))
        }
      } else {
        try Data(line.utf8).write(to: url)
      }
    } catch {
      logger.error("latency log write failed")
    }
  }
}
