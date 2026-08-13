import AVFoundation
import Foundation

/// Instant start/stop cues for dictation. Samples are synthesized once into
/// memory and kept in prepared `AVAudioPlayer`s so hotkey playback has no
/// file I/O and no first-play hitch.
@MainActor
final class DictationSoundService {
  static let shared = DictationSoundService()

  private var startPlayer: AVAudioPlayer?
  private var stopPlayer: AVAudioPlayer?
  private var didPrepare = false

  /// Soft peak  -  present, never shouty over speech or UI.
  private let playbackVolume: Float = 0.20

  func prepare() {
    guard !didPrepare else {
      startPlayer?.prepareToPlay()
      stopPlayer?.prepareToPlay()
      return
    }
    didPrepare = true

    startPlayer = makePlayer(wavData: Self.renderCue(kind: .start))
    stopPlayer = makePlayer(wavData: Self.renderCue(kind: .stop))

    // Prime the audio path once at zero volume so the first real cue is cold-free.
    for player in [startPlayer, stopPlayer].compactMap({ $0 }) {
      let saved = player.volume
      player.volume = 0
      player.play()
      player.stop()
      player.currentTime = 0
      player.volume = saved
      player.prepareToPlay()
    }
  }

  func playStart() {
    prepare()
    retrigger(startPlayer)
  }

  func playStop() {
    prepare()
    retrigger(stopPlayer)
  }

  private func retrigger(_ player: AVAudioPlayer?) {
    guard let player else { return }
    // Stop-then-play from 0 so rapid re-triggers never queue behind a tail.
    if player.isPlaying {
      player.stop()
    }
    player.currentTime = 0
    player.play()
  }

  private func makePlayer(wavData: Data) -> AVAudioPlayer? {
    do {
      let player = try AVAudioPlayer(data: wavData)
      player.volume = playbackVolume
      player.numberOfLoops = 0
      player.prepareToPlay()
      return player
    } catch {
      return nil
    }
  }

  private enum CueKind {
    case start
    case stop
  }

  /// Hand-tuned soft chirps  -  short sine sweeps with a gentle harmonic and
  /// exponential air, rendered at 48 kHz for a clean DAC path.
  private static func renderCue(kind: CueKind) -> Data {
    let sampleRate = 48_000.0
    let duration: Double
    let f0: Double
    let f1: Double
    let peak: Double

    switch kind {
    case .start:
      // Soft “open”  -  quick lift, ~48 ms.
      duration = 0.048
      f0 = 880
      f1 = 1_320
      peak = 0.55
    case .stop:
      // Soft “close”  -  slightly longer settle, ~62 ms.
      duration = 0.062
      f0 = 740
      f1 = 380
      peak = 0.48
    }

    let count = Int(sampleRate * duration)
    var samples = [Int16](repeating: 0, count: count)
    let twoPi = 2.0 * Double.pi
    var phase = 0.0

    for i in 0..<count {
      let t = Double(i) / sampleRate
      let progress = t / duration

      // Smooth frequency sweep (ease-in-out).
      let sweep = progress * progress * (3 - 2 * progress)
      let freq = f0 + (f1 - f0) * sweep
      phase += twoPi * freq / sampleRate
      if phase > twoPi { phase -= twoPi }

      // Fundamental + quiet 2nd harmonic for a less “pure beep” timbre.
      let fundamental = sin(phase)
      let harmonic = 0.18 * sin(2 * phase)
      var signal = fundamental + harmonic

      // Tiny noise tick on the attack only  -  tactile without harshness.
      if progress < 0.08 {
        let noise = Double.random(in: -1...1) * (1 - progress / 0.08)
        signal += 0.04 * noise
      }

      // Envelope: ~2 ms cosine attack, exponential decay, cosine release.
      let attack = min(1, t / 0.002)
      let attackShape = 0.5 - 0.5 * cos(Double.pi * attack)
      let decay = exp(-progress * (kind == .start ? 4.2 : 3.4))
      let releaseStart = 0.78
      let release: Double
      if progress < releaseStart {
        release = 1
      } else {
        let u = (progress - releaseStart) / (1 - releaseStart)
        release = 0.5 + 0.5 * cos(Double.pi * u)
      }
      let envelope = attackShape * decay * release * peak

      let clipped = max(-1, min(1, signal * envelope))
      samples[i] = Int16((clipped * Double(Int16.max - 1)).rounded())
    }

    return wavData(samples: samples, sampleRate: Int(sampleRate))
  }

  private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
    let dataSize = samples.count * MemoryLayout<Int16>.size
    var data = Data(capacity: 44 + dataSize)

    func appendASCII(_ string: String) {
      data.append(contentsOf: string.utf8)
    }
    func appendUInt16(_ value: UInt16) {
      var le = value.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    func appendUInt32(_ value: UInt32) {
      var le = value.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    appendASCII("RIFF")
    appendUInt32(UInt32(36 + dataSize))
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendUInt32(16)
    appendUInt16(1)
    appendUInt16(1)
    appendUInt32(UInt32(sampleRate))
    appendUInt32(UInt32(sampleRate * MemoryLayout<Int16>.size))
    appendUInt16(UInt16(MemoryLayout<Int16>.size))
    appendUInt16(16)
    appendASCII("data")
    appendUInt32(UInt32(dataSize))
    for sample in samples {
      var le = sample.littleEndian
      withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    return data
  }
}
