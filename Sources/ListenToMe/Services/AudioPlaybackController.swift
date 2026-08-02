import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published private(set) var isPlaying = false
  @Published private(set) var currentTime: TimeInterval = 0
  @Published private(set) var duration: TimeInterval = 0

  private var player: AVAudioPlayer?
  private var timer: Timer?
  private var loadedURL: URL?

  func load(_ url: URL) {
    guard loadedURL != url else { return }
    stop()
    loadedURL = url

    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.delegate = self
      player.prepareToPlay()
      self.player = player
      duration = player.duration
    } catch {
      player = nil
      duration = 0
    }
  }

  func toggle() {
    guard let player else { return }
    if player.isPlaying {
      player.pause()
      isPlaying = false
      timer?.invalidate()
    } else {
      player.play()
      isPlaying = true
      startTimer()
    }
  }

  func stop() {
    player?.stop()
    player?.currentTime = 0
    timer?.invalidate()
    timer = nil
    isPlaying = false
    currentTime = 0
  }

  func audioPlayerDidFinishPlaying(
    _ player: AVAudioPlayer,
    successfully flag: Bool
  ) {
    isPlaying = false
    currentTime = 0
    timer?.invalidate()
    timer = nil
  }

  private func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.currentTime = self.player?.currentTime ?? 0
      }
    }
  }
}
