import AVFoundation
import Foundation

/// File transcription for history recovery and imported audio.
enum FileTranscriptionService {
  static let openAIModel = "gpt-transcribe"
  static let geminiModel = "gemini-3.5-transcribe"
  static let maximumUploadChunkDuration: TimeInterval = 45 * 60

  enum ServiceError: LocalizedError {
    case missingAudio
    case conversionFailed
    case httpStatus(Int, String)
    case emptyTranscript
    case invalidResponse
    case missingUploadLocation
    case processingFailed(String)

    var errorDescription: String? {
      switch self {
      case .missingAudio: "This history item has no audio file to reprocess."
      case .conversionFailed: "The recording could not be prepared for transcription."
      case .httpStatus(let code, let body):
        body.isEmpty ? "Transcription failed (HTTP \(code))." : body
      case .emptyTranscript: "No speech was found in that recording."
      case .invalidResponse: "The transcription response was unreadable."
      case .missingUploadLocation: "Gemini did not provide an audio upload address."
      case .processingFailed(let detail):
        detail.isEmpty ? "Gemini could not process that audio file." : detail
      }
    }
  }

  static func transcribe(
    audioURL: URL,
    provider: TranscriptionProvider,
    apiKey: String,
    configuration: TranscriptionConfiguration
  ) async throws -> String {
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw ServiceError.missingAudio
    }

    let uploadURLs = try await Task.detached(priority: .userInitiated) {
      try makeUploadFiles(from: audioURL)
    }.value
    defer {
      for uploadURL in uploadURLs {
        _ = try? FileManager.default.trashItem(
          at: uploadURL,
          resultingItemURL: nil
        )
      }
    }

    var transcripts: [String] = []
    transcripts.reserveCapacity(uploadURLs.count)
    for uploadURL in uploadURLs {
      let transcript: String
      switch provider {
      case .openAI:
        transcript = try await transcribeOpenAI(
          fileURL: uploadURL,
          apiKey: apiKey,
          prompt: configuration.prompt,
          language: configuration.languages.first
        )
      case .gemini:
        transcript = try await transcribeGemini(
          fileURL: uploadURL,
          apiKey: apiKey,
          configuration: configuration
        )
      }
      transcripts.append(transcript)
    }
    return transcripts.joined(separator: "\n\n")
  }

  private static func transcribeOpenAI(
    fileURL: URL,
    apiKey: String,
    prompt: String,
    language: String?
  ) async throws -> String {
    var body = Data()
    let boundary = "ListenToMe-\(UUID().uuidString)"

    func append(_ string: String) {
      body.append(Data(string.utf8))
    }

    append("--\(boundary)\r\n")
    append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
    )
    append("Content-Type: audio/mp4\r\n\r\n")
    body.append(try Data(contentsOf: fileURL))
    append("\r\n")

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
    append("\(openAIModel)\r\n")

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedPrompt.isEmpty {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
      append("\(trimmedPrompt)\r\n")
    }

    if let language, !language.isEmpty {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
      append("\(language)\r\n")
    }

    append("--\(boundary)--\r\n")

    var request = URLRequest(
      url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    )
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.timeoutInterval = 10 * 60
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)
    try throwIfNeeded(data: data, response: response)
    return try decodeOpenAITranscript(data)
  }

  private static func transcribeGemini(
    fileURL: URL,
    apiKey: String,
    configuration: TranscriptionConfiguration
  ) async throws -> String {
    let remote = try await uploadToGemini(fileURL: fileURL, apiKey: apiKey)
    do {
      let ready = try await waitForGeminiFile(remote, apiKey: apiKey)
      let text = try await createGeminiInteraction(
        file: ready,
        apiKey: apiKey,
        configuration: configuration
      )
      await deleteGeminiFile(ready.name, apiKey: apiKey)
      return text
    } catch {
      await deleteGeminiFile(remote.name, apiKey: apiKey)
      throw error
    }
  }

  private struct GeminiFile: Sendable {
    let name: String
    let uri: String
    let mimeType: String
    let state: String
  }

  private static func uploadToGemini(
    fileURL: URL,
    apiKey: String
  ) async throws -> GeminiFile {
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
    guard let byteCount = values.fileSize, byteCount > 0 else {
      throw ServiceError.missingAudio
    }
    var start = URLRequest(
      url: URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
    )
    start.httpMethod = "POST"
    start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    start.setValue("resumable", forHTTPHeaderField: "x-goog-upload-protocol")
    start.setValue("start", forHTTPHeaderField: "x-goog-upload-command")
    start.setValue(String(byteCount), forHTTPHeaderField: "x-goog-upload-header-content-length")
    start.setValue("audio/mp4", forHTTPHeaderField: "x-goog-upload-header-content-type")
    start.setValue("application/json", forHTTPHeaderField: "Content-Type")
    start.timeoutInterval = 10 * 60
    start.httpBody = try JSONSerialization.data(withJSONObject: [
      "file": ["display_name": fileURL.lastPathComponent]
    ])

    let (startData, startResponse) = try await URLSession.shared.data(for: start)
    try throwIfNeeded(data: startData, response: startResponse)
    guard let http = startResponse as? HTTPURLResponse,
      let location = http.value(forHTTPHeaderField: "x-goog-upload-url"),
      let uploadURL = URL(string: location)
    else {
      throw ServiceError.missingUploadLocation
    }

    var upload = URLRequest(url: uploadURL)
    upload.httpMethod = "POST"
    upload.setValue("0", forHTTPHeaderField: "x-goog-upload-offset")
    upload.setValue("upload, finalize", forHTTPHeaderField: "x-goog-upload-command")
    upload.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")
    upload.timeoutInterval = 10 * 60

    let (data, response) = try await URLSession.shared.upload(
      for: upload,
      fromFile: fileURL
    )
    try throwIfNeeded(data: data, response: response)
    return try decodeGeminiFile(data)
  }

  private static func waitForGeminiFile(
    _ file: GeminiFile,
    apiKey: String
  ) async throws -> GeminiFile {
    var current = file
    let deadline = Date().addingTimeInterval(10 * 60)
    while Date() < deadline {
      try Task.checkCancellation()
      switch current.state.uppercased() {
      case "ACTIVE", "": return current
      case "FAILED": throw ServiceError.processingFailed("")
      default: break
      }
      try await Task.sleep(nanoseconds: 1_000_000_000)
      var request = URLRequest(
        url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(current.name)")!
      )
      request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
      request.timeoutInterval = 60
      let (data, response) = try await URLSession.shared.data(for: request)
      try throwIfNeeded(data: data, response: response)
      current = try decodeGeminiFile(data)
    }
    throw ServiceError.processingFailed("Gemini took too long to prepare the audio.")
  }

  private static func createGeminiInteraction(
    file: GeminiFile,
    apiKey: String,
    configuration: TranscriptionConfiguration
  ) async throws -> String {
    var request = URLRequest(
      url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    )
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10 * 60
    request.httpBody = try JSONSerialization.data(
      withJSONObject: geminiInteractionBody(
        fileURI: file.uri,
        mimeType: file.mimeType.isEmpty ? "audio/mp4" : file.mimeType,
        configuration: configuration
      )
    )

    let (data, response) = try await URLSession.shared.data(for: request)
    try throwIfNeeded(data: data, response: response)
    return try decodeGeminiTranscript(data)
  }

  static func geminiInteractionBody(
    fileURI: String,
    mimeType: String,
    configuration: TranscriptionConfiguration
  ) -> [String: Any] {
    var transcription: [String: Any] = [
      "mode": ["type": "smart"]
    ]
    if !configuration.languages.isEmpty {
      transcription["language_codes"] = configuration.languages
    }
    let terms = Array(
      configuration.keywords
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .prefix(1_000)
    )
    if !terms.isEmpty {
      transcription["custom_vocabulary"] = terms
    }

    return [
      "model": geminiModel,
      "input": [
        [
          "type": "audio",
          "uri": fileURI,
          "mime_type": mimeType,
        ]
      ],
      "generation_config": [
        "transcription_config": transcription
      ],
    ]
  }

  static func decodeGeminiTranscript(_ data: Data) throws -> String {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw ServiceError.invalidResponse }

    if let output = object["output_text"] as? String {
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    var pieces: [String] = []
    if let steps = object["steps"] as? [[String: Any]] {
      for step in steps {
        if let content = step["content"] as? [[String: Any]] {
          pieces.append(contentsOf: content.compactMap { $0["text"] as? String })
        } else if let content = step["content"] as? [String: Any],
          let text = content["text"] as? String
        {
          pieces.append(text)
        }
      }
    }

    let text =
      pieces
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    guard !text.isEmpty else { throw ServiceError.emptyTranscript }
    return text
  }

  private static func deleteGeminiFile(_ name: String, apiKey: String) async {
    guard !name.isEmpty,
      let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)")
    else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    _ = try? await URLSession.shared.data(for: request)
  }

  private static func decodeGeminiFile(_ data: Data) throws -> GeminiFile {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw ServiceError.invalidResponse }
    let file = (object["file"] as? [String: Any]) ?? object
    guard let name = file["name"] as? String,
      let uri = file["uri"] as? String
    else { throw ServiceError.invalidResponse }
    return GeminiFile(
      name: name,
      uri: uri,
      mimeType: file["mimeType"] as? String ?? file["mime_type"] as? String ?? "audio/mp4",
      state: file["state"] as? String ?? ""
    )
  }

  private static func throwIfNeeded(data: Data, response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw ServiceError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body =
        String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw ServiceError.httpStatus(http.statusCode, String(body.prefix(280)))
    }
  }

  private static func decodeOpenAITranscript(_ data: Data) throws -> String {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = object["text"] as? String
    else { throw ServiceError.invalidResponse }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ServiceError.emptyTranscript }
    return trimmed
  }

  static func uploadChunkRanges(
    totalFrames: AVAudioFramePosition,
    sampleRate: Double
  ) -> [Range<AVAudioFramePosition>] {
    guard totalFrames > 0, sampleRate > 0 else { return [] }
    let framesPerChunk = max(
      AVAudioFramePosition(sampleRate * maximumUploadChunkDuration),
      1
    )
    var ranges: [Range<AVAudioFramePosition>] = []
    var lowerBound: AVAudioFramePosition = 0
    while lowerBound < totalFrames {
      let upperBound = min(totalFrames, lowerBound + framesPerChunk)
      ranges.append(lowerBound..<upperBound)
      lowerBound = upperBound
    }
    return ranges
  }

  static func makeUploadFiles(from sourceURL: URL) throws -> [URL] {
    let source = try AVAudioFile(forReading: sourceURL)
    let sourceFormat = source.processingFormat
    let ranges = uploadChunkRanges(
      totalFrames: source.length,
      sampleRate: sourceFormat.sampleRate
    )
    guard !ranges.isEmpty else { throw ServiceError.missingAudio }

    var outputURLs: [URL] = []
    do {
      for range in ranges {
        let outputURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("listentome-transcribe-\(UUID().uuidString)")
          .appendingPathExtension("m4a")
        do {
          try encodeUploadChunk(
            from: sourceURL,
            sourceRange: range,
            to: outputURL
          )
        } catch {
          if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try? FileManager.default.trashItem(
              at: outputURL,
              resultingItemURL: nil
            )
          }
          throw error
        }
        outputURLs.append(outputURL)
      }
      return outputURLs
    } catch {
      for outputURL in outputURLs {
        _ = try? FileManager.default.trashItem(
          at: outputURL,
          resultingItemURL: nil
        )
      }
      throw error
    }
  }

  private static func encodeUploadChunk(
    from sourceURL: URL,
    sourceRange: Range<AVAudioFramePosition>,
    to outputURL: URL
  ) throws {
    let input = try AVAudioFile(forReading: sourceURL)
    input.framePosition = sourceRange.lowerBound

    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 24_000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 48_000,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    let output = try AVAudioFile(
      forWriting: outputURL,
      settings: outputSettings,
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let inputFormat = input.processingFormat
    let outputFormat = output.processingFormat
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else { throw ServiceError.conversionFailed }

    let inputCapacity: AVAudioFrameCount = 32_768
    let rateRatio = outputFormat.sampleRate / inputFormat.sampleRate
    let outputCapacity = max(
      AVAudioFrameCount((Double(inputCapacity) * rateRatio).rounded(.up)) + 1_024,
      4_096
    )
    guard
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: inputCapacity
      ),
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: outputCapacity
      )
    else { throw ServiceError.conversionFailed }

    var reachedEnd = false
    var readError: Error?
    while true {
      outputBuffer.frameLength = 0
      var conversionError: NSError?
      let status = converter.convert(
        to: outputBuffer,
        error: &conversionError
      ) { _, inputStatus in
        if reachedEnd {
          inputStatus.pointee = .endOfStream
          return nil
        }

        let remaining = sourceRange.upperBound - input.framePosition
        guard remaining > 0 else {
          reachedEnd = true
          inputStatus.pointee = .endOfStream
          return nil
        }

        do {
          try input.read(
            into: inputBuffer,
            frameCount: min(inputCapacity, AVAudioFrameCount(remaining))
          )
        } catch {
          readError = error
          inputStatus.pointee = .noDataNow
          return nil
        }
        guard inputBuffer.frameLength > 0 else {
          reachedEnd = true
          inputStatus.pointee = .endOfStream
          return nil
        }
        inputStatus.pointee = .haveData
        return inputBuffer
      }

      if let readError { throw readError }
      if let conversionError { throw conversionError }
      if outputBuffer.frameLength > 0 {
        try output.write(from: outputBuffer)
      }

      switch status {
      case .haveData, .inputRanDry:
        continue
      case .endOfStream:
        return
      case .error:
        throw ServiceError.conversionFailed
      @unknown default:
        throw ServiceError.conversionFailed
      }
    }
  }
}
