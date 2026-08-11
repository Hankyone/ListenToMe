import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture with VoiceInk/Handy-style warm-up.
///
/// Cold `AVAudioEngine.start()` regularly costs hundreds of ms (Handy #1283).
/// We keep the graph warm between takes for 30s so the next hotkey only flips
/// a flag and opens the recording file — speech is captured immediately.
final class AudioCaptureService {
  enum CaptureError: LocalizedError {
    case invalidInputFormat
    case converterUnavailable
    case alreadyRecording
    case deviceUnavailable

    var errorDescription: String? {
      switch self {
      case .invalidInputFormat: "The selected microphone has no usable audio format."
      case .converterUnavailable: "The microphone audio could not be prepared for OpenAI."
      case .alreadyRecording: "A recording is already in progress."
      case .deviceUnavailable: "That microphone isn’t available. Pick another in Setup."
      }
    }
  }

  private enum Mode {
    case idle
    case warm
    case recording
  }

  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var converter: AVAudioConverter?
  private var pendingPCM = Data()
  private var lastLevelUpdate = Date.distantPast
  private var mode: Mode = .idle
  private var warmedDeviceUID: String?
  private var coolDownTask: Task<Void, Never>?

  private var onPCMChunk: ((Data) -> Void)?
  private var onLevel: ((Float) -> Void)?
  private var onError: ((Error) -> Void)?

  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: true
  )!

  /// ~40ms of 24 kHz mono Int16 — snappier first bytes to the API.
  private let targetChunkSize = 1_920
  /// Handy keeps the stream open ~30s after a take for back-to-back dictation.
  private let keepAliveNanoseconds: UInt64 = 30_000_000_000

  var isRecording: Bool {
    lock.lock()
    defer { lock.unlock() }
    return mode == .recording
  }

  /// Spin up the HAL graph without writing a take. Safe to call on launch and
  /// after each stop; no-ops when already warm for the same device.
  func prepare(deviceUID: String = MicrophoneInput.systemDefaultID) throws {
    coolDownTask?.cancel()
    coolDownTask = nil

    lock.lock()
    let alreadyWarm = mode == .warm || mode == .recording
    let sameDevice = warmedDeviceUID == deviceUID
    lock.unlock()
    if alreadyWarm, sameDevice { return }

    tearDownEngine()
    try buildEngine(deviceUID: deviceUID, recordingURL: nil)
  }

  func start(
    recordingURL: URL,
    deviceUID: String = MicrophoneInput.systemDefaultID,
    onPCMChunk: @escaping (Data) -> Void,
    onLevel: @escaping (Float) -> Void,
    onError: @escaping (Error) -> Void
  ) throws {
    coolDownTask?.cancel()
    coolDownTask = nil

    lock.lock()
    if mode == .recording {
      lock.unlock()
      throw CaptureError.alreadyRecording
    }
    let canPromoteWarm = mode == .warm && warmedDeviceUID == deviceUID && engine != nil
    lock.unlock()

    self.onPCMChunk = onPCMChunk
    self.onLevel = onLevel
    self.onError = onError

    if canPromoteWarm {
      try beginRecording(to: recordingURL)
      return
    }

    tearDownEngine()
    try buildEngine(deviceUID: deviceUID, recordingURL: recordingURL)
  }

  /// End the take but keep the graph warm briefly for the next hotkey.
  func stop() -> Data? {
    lock.lock()
    guard mode == .recording else {
      lock.unlock()
      return nil
    }
    mode = .warm
    audioFile = nil
    let remainder = pendingPCM
    pendingPCM.removeAll(keepingCapacity: false)
    lock.unlock()

    onPCMChunk = nil
    onLevel = nil
    // Keep onError while warm in case the tap faults.
    scheduleCoolDown()
    return remainder.isEmpty ? nil : remainder
  }

  func cancel() {
    coolDownTask?.cancel()
    coolDownTask = nil
    tearDownEngine()
    onPCMChunk = nil
    onLevel = nil
    onError = nil
  }

  private func scheduleCoolDown() {
    coolDownTask?.cancel()
    coolDownTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: self?.keepAliveNanoseconds ?? 30_000_000_000)
      guard !Task.isCancelled else { return }
      self?.coolDownIfStillWarm()
    }
  }

  private func coolDownIfStillWarm() {
    lock.lock()
    let stillWarm = mode == .warm
    lock.unlock()
    guard stillWarm else { return }
    tearDownEngine()
    onError = nil
  }

  private func beginRecording(to recordingURL: URL) throws {
    guard let engine else { throw CaptureError.deviceUnavailable }
    let input = engine.inputNode
    let hardwareFormat = input.inputFormat(forBus: 0)
    guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
      throw CaptureError.invalidInputFormat
    }
    let tapFormat =
      AVAudioFormat(
        standardFormatWithSampleRate: hardwareFormat.sampleRate,
        channels: 1
      ) ?? hardwareFormat

    let audioFile = try AVAudioFile(
      forWriting: recordingURL,
      settings: tapFormat.settings
    )

    lock.lock()
    self.audioFile = audioFile
    pendingPCM.removeAll(keepingCapacity: true)
    lastLevelUpdate = .distantPast
    mode = .recording
    lock.unlock()
  }

  private func buildEngine(deviceUID: String, recordingURL: URL?) throws {
    let engine = AVAudioEngine()
    let input = engine.inputNode

    if let deviceID = MicrophoneInputCatalog.deviceID(forUID: deviceUID) {
      try selectInputDevice(deviceID, on: input)
    }

    let hardwareFormat = input.inputFormat(forBus: 0)
    guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
      throw CaptureError.invalidInputFormat
    }

    let tapFormat =
      AVAudioFormat(
        standardFormatWithSampleRate: hardwareFormat.sampleRate,
        channels: 1
      ) ?? hardwareFormat

    guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
      throw CaptureError.converterUnavailable
    }

    let audioFile: AVAudioFile?
    if let recordingURL {
      audioFile = try AVAudioFile(
        forWriting: recordingURL,
        settings: tapFormat.settings
      )
    } else {
      audioFile = nil
    }

    self.engine = engine
    self.audioFile = audioFile
    self.converter = converter
    pendingPCM.removeAll(keepingCapacity: true)
    lastLevelUpdate = .distantPast
    warmedDeviceUID = deviceUID
    mode = recordingURL == nil ? .warm : .recording

    // Smaller buffer = less hardware latency before the first callback.
    input.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) {
      [weak self] buffer, _ in
      guard let self else { return }
      self.handleTap(buffer: buffer, converter: converter)
    }

    engine.prepare()
    try engine.start()
  }

  private func handleTap(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
    lock.lock()
    let currentMode = mode
    let file = audioFile
    let pcmHandler = onPCMChunk
    let levelHandler = onLevel
    let errorHandler = onError
    lock.unlock()

    guard currentMode == .warm || currentMode == .recording else { return }

    do {
      if currentMode == .recording, let file {
        try file.write(from: buffer)
      }

      // Levels while warm keep the next overlay snappy; PCM only while recording.
      let now = Date()
      if now.timeIntervalSince(lastLevelUpdate) >= 0.05 {
        lastLevelUpdate = now
        levelHandler?(Self.normalizedLevel(buffer))
      }

      guard currentMode == .recording, let pcmHandler else { return }
      if let converted = convert(buffer, with: converter) {
        enqueue(converted, onPCMChunk: pcmHandler)
      }
    } catch {
      errorHandler?(error)
    }
  }

  private func tearDownEngine() {
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    engine = nil
    audioFile = nil
    converter = nil
    warmedDeviceUID = nil
    lock.lock()
    mode = .idle
    pendingPCM.removeAll(keepingCapacity: false)
    lock.unlock()
  }

  private func selectInputDevice(
    _ deviceID: AudioDeviceID,
    on input: AVAudioInputNode
  ) throws {
    guard let audioUnit = input.audioUnit else {
      throw CaptureError.deviceUnavailable
    }
    var id = deviceID
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &id,
      size
    )
    guard status == noErr else {
      throw CaptureError.deviceUnavailable
    }
  }

  private func enqueue(_ data: Data, onPCMChunk: @escaping (Data) -> Void) {
    lock.lock()
    pendingPCM.append(data)

    var chunks: [Data] = []
    while pendingPCM.count >= targetChunkSize {
      chunks.append(Data(pendingPCM.prefix(targetChunkSize)))
      pendingPCM.removeFirst(targetChunkSize)
    }
    lock.unlock()

    chunks.forEach(onPCMChunk)
  }

  private func convert(
    _ buffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter
  ) -> Data? {
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let outputCapacity = AVAudioFrameCount(
      max(1, ceil(Double(buffer.frameLength) * ratio) + 8)
    )
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputCapacity
      )
    else {
      return nil
    }

    var didSupplyInput = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) {
      _, inputStatus in
      if didSupplyInput {
        inputStatus.pointee = .noDataNow
        return nil
      }
      didSupplyInput = true
      inputStatus.pointee = .haveData
      return buffer
    }

    guard conversionError == nil,
      status == .haveData || status == .inputRanDry,
      output.frameLength > 0
    else {
      return nil
    }

    let audioBuffer = output.audioBufferList.pointee.mBuffers
    guard let bytes = audioBuffer.mData else { return nil }
    return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
  }

  private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?.pointee else { return 0 }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }

    var sum: Float = 0
    for index in 0..<count {
      let sample = samples[index]
      sum += sample * sample
    }

    let rms = sqrt(sum / Float(count))
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    return min(1, max(0, (decibels + 55) / 55))
  }
}
