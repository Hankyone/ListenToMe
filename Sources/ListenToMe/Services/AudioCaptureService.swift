import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture with VoiceInk/Handy-style warm-up.
///
/// All HAL / `AVAudioEngine` work runs on `hardwareQueue`  -  never on the
/// main actor. The graph is prepared while idle, but the engine is **stopped**
/// so macOS does not show the orange mic privacy indicator between takes.
/// Hotkey only needs `engine.start()`, which is far cheaper than rebuilding.
final class AudioCaptureService: @unchecked Sendable {
  enum CaptureError: LocalizedError {
    case invalidInputFormat
    case converterUnavailable
    case alreadyRecording
    case deviceUnavailable

    var errorDescription: String? {
      switch self {
      case .invalidInputFormat: "The selected microphone has no usable audio format."
      case .converterUnavailable: "The microphone audio could not be prepared for transcription."
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

  private let hardwareQueue = DispatchQueue(
    label: "ca.hankyone.ListenToMe.audio",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var converter: AVAudioConverter?
  private var pendingPCM = Data()
  private var lastLevelUpdate = Date.distantPast
  private var mode: Mode = .idle
  private var warmedDeviceUID: String?
  private var warmedSampleRate: Double?
  private var coolDownWorkItem: DispatchWorkItem?

  private var onPCMChunk: ((Data) -> Void)?
  private var onLevel: ((Float) -> Void)?
  private var onError: ((Error) -> Void)?

  private var targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: true
  )!

  private var targetChunkSize = 1_920
  /// Handy keeps the graph warm ~30s after a take for back-to-back dictation
  /// (engine stopped  -  no orange mic light while waiting).
  private let keepAliveSeconds: TimeInterval = 30

  var isRecording: Bool {
    lock.lock()
    defer { lock.unlock() }
    return mode == .recording
  }

  /// Build/prepare the HAL graph without starting capture (no privacy light).
  func prepare(
    deviceUID: String = MicrophoneInput.systemDefaultID,
    sampleRate: Double = 24_000,
    chunkByteCount: Int = 1_920
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      hardwareQueue.async {
        do {
          try self.prepareSync(
            deviceUID: deviceUID,
            sampleRate: sampleRate,
            chunkByteCount: chunkByteCount
          )
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Graph is ready so the next `start` only needs `engine.start()`.
  var isWarm: Bool {
    lock.lock()
    defer { lock.unlock() }
    return mode == .warm && engine != nil
  }

  func start(
    recordingURL: URL,
    deviceUID: String = MicrophoneInput.systemDefaultID,
    sampleRate: Double = 24_000,
    chunkByteCount: Int = 1_920,
    onPCMChunk: @escaping (Data) -> Void,
    onLevel: @escaping (Float) -> Void,
    onError: @escaping (Error) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      hardwareQueue.async {
        do {
          try self.startSync(
            recordingURL: recordingURL,
            deviceUID: deviceUID,
            sampleRate: sampleRate,
            chunkByteCount: chunkByteCount,
            onPCMChunk: onPCMChunk,
            onLevel: onLevel,
            onError: onError
          )
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// End the take but keep the graph warm briefly for the next hotkey.
  func stop() async -> Data? {
    await withCheckedContinuation { continuation in
      hardwareQueue.async {
        continuation.resume(returning: self.stopSync())
      }
    }
  }

  func cancel() async {
    await withCheckedContinuation { continuation in
      hardwareQueue.async {
        self.cancelSync()
        continuation.resume()
      }
    }
  }

  // MARK: - Hardware queue (sync)

  private func prepareSync(
    deviceUID: String,
    sampleRate: Double,
    chunkByteCount: Int
  ) throws {
    coolDownWorkItem?.cancel()
    coolDownWorkItem = nil

    lock.lock()
    let alreadyWarm = mode == .warm || mode == .recording
    let isRecordingNow = mode == .recording
    let sameDevice = warmedDeviceUID == deviceUID
    let sameSampleRate = warmedSampleRate == sampleRate
    let engine = self.engine
    lock.unlock()
    if alreadyWarm, sameDevice, sameSampleRate, engine != nil {
      targetChunkSize = chunkByteCount
      // Stay prepared, but never leave the mic running while idle.
      if let engine, engine.isRunning, !isRecordingNow {
        engine.stop()
      }
      return
    }

    tearDownEngine()
    try buildEngine(
      deviceUID: deviceUID,
      sampleRate: sampleRate,
      chunkByteCount: chunkByteCount,
      recordingURL: nil,
      startImmediately: false
    )
  }

  private func startSync(
    recordingURL: URL,
    deviceUID: String,
    sampleRate: Double,
    chunkByteCount: Int,
    onPCMChunk: @escaping (Data) -> Void,
    onLevel: @escaping (Float) -> Void,
    onError: @escaping (Error) -> Void
  ) throws {
    coolDownWorkItem?.cancel()
    coolDownWorkItem = nil

    lock.lock()
    if mode == .recording {
      lock.unlock()
      throw CaptureError.alreadyRecording
    }
    let canPromoteWarm =
      mode == .warm
      && warmedDeviceUID == deviceUID
      && warmedSampleRate == sampleRate
      && engine != nil
    lock.unlock()

    self.onPCMChunk = onPCMChunk
    self.onLevel = onLevel
    self.onError = onError
    targetChunkSize = chunkByteCount

    if canPromoteWarm {
      try beginRecording(to: recordingURL)
      return
    }

    tearDownEngine()
    try buildEngine(
      deviceUID: deviceUID,
      sampleRate: sampleRate,
      chunkByteCount: chunkByteCount,
      recordingURL: recordingURL,
      startImmediately: true
    )
  }

  private func stopSync() -> Data? {
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
    // Stop capture so the orange mic indicator goes out; keep the graph for
    // a fast engine.start() on the next hotkey.
    if let engine, engine.isRunning {
      engine.stop()
    }
    scheduleCoolDown()
    return remainder.isEmpty ? nil : remainder
  }

  private func cancelSync() {
    coolDownWorkItem?.cancel()
    coolDownWorkItem = nil
    tearDownEngine()
    onPCMChunk = nil
    onLevel = nil
    onError = nil
  }

  private func scheduleCoolDown() {
    coolDownWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.coolDownIfStillWarm()
    }
    coolDownWorkItem = work
    hardwareQueue.asyncAfter(deadline: .now() + keepAliveSeconds, execute: work)
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

    if !engine.isRunning {
      try engine.start()
    }
  }

  private func buildEngine(
    deviceUID: String,
    sampleRate: Double,
    chunkByteCount: Int,
    recordingURL: URL?,
    startImmediately: Bool
  ) throws {
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

    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
      ), let converter = AVAudioConverter(from: tapFormat, to: targetFormat)
    else {
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
    self.targetFormat = targetFormat
    targetChunkSize = chunkByteCount
    pendingPCM.removeAll(keepingCapacity: true)
    lastLevelUpdate = .distantPast
    warmedDeviceUID = deviceUID
    warmedSampleRate = sampleRate
    mode = recordingURL == nil ? .warm : .recording

    input.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) {
      [weak self] buffer, _ in
      guard let self else { return }
      self.handleTap(buffer: buffer, converter: converter)
    }

    engine.prepare()
    // Only run the engine while actively recording  -  a running input keeps
    // the macOS orange mic indicator lit.
    if startImmediately {
      try engine.start()
    }
  }

  private func handleTap(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
    lock.lock()
    let currentMode = mode
    let file = audioFile
    let pcmHandler = onPCMChunk
    let levelHandler = onLevel
    let errorHandler = onError
    lock.unlock()

    // Engine only runs in .recording now; ignore stray callbacks.
    guard currentMode == .recording else { return }

    do {
      if currentMode == .recording, let file {
        try file.write(from: buffer)
      }

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
    warmedSampleRate = nil
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
