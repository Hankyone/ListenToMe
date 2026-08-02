import AVFoundation
import Foundation

final class AudioCaptureService {
  enum CaptureError: LocalizedError {
    case invalidInputFormat
    case converterUnavailable
    case alreadyRecording

    var errorDescription: String? {
      switch self {
      case .invalidInputFormat: "The selected microphone has no usable audio format."
      case .converterUnavailable: "The microphone audio could not be prepared for OpenAI."
      case .alreadyRecording: "A recording is already in progress."
      }
    }
  }

  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var converter: AVAudioConverter?
  private var pendingPCM = Data()
  private var lastLevelUpdate = Date.distantPast

  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: true
  )!

  func start(
    recordingURL: URL,
    onPCMChunk: @escaping (Data) -> Void,
    onLevel: @escaping (Float) -> Void,
    onError: @escaping (Error) -> Void
  ) throws {
    guard engine == nil else { throw CaptureError.alreadyRecording }

    let engine = AVAudioEngine()
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

    guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
      throw CaptureError.converterUnavailable
    }

    let audioFile = try AVAudioFile(
      forWriting: recordingURL,
      settings: tapFormat.settings
    )

    self.engine = engine
    self.audioFile = audioFile
    self.converter = converter
    pendingPCM.removeAll(keepingCapacity: true)
    lastLevelUpdate = .distantPast

    input.installTap(onBus: 0, bufferSize: 4_096, format: tapFormat) {
      [weak self] buffer, _ in
      guard let self else { return }

      do {
        try audioFile.write(from: buffer)
        if let converted = self.convert(buffer, with: converter) {
          self.enqueue(converted, onPCMChunk: onPCMChunk)
        }

        let now = Date()
        if now.timeIntervalSince(self.lastLevelUpdate) >= 0.06 {
          self.lastLevelUpdate = now
          onLevel(Self.normalizedLevel(buffer))
        }
      } catch {
        onError(error)
      }
    }

    engine.prepare()
    try engine.start()
  }

  func stop() -> Data? {
    guard let engine else { return nil }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    self.engine = nil
    audioFile = nil
    converter = nil

    lock.lock()
    let remainder = pendingPCM
    pendingPCM.removeAll(keepingCapacity: false)
    lock.unlock()
    return remainder.isEmpty ? nil : remainder
  }

  func cancel() {
    _ = stop()
  }

  private func enqueue(_ data: Data, onPCMChunk: @escaping (Data) -> Void) {
    let targetChunkSize = 4_800
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
