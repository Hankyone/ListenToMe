import AVFoundation
import Foundation

/// Offline / history reprocessing via OpenAI or OpenRouter audio transcription.
enum FileTranscriptionService {
  enum ServiceError: LocalizedError {
    case missingAudio
    case conversionFailed
    case httpStatus(Int, String)
    case emptyTranscript
    case invalidResponse

    var errorDescription: String? {
      switch self {
      case .missingAudio: "This history item has no audio file to reprocess."
      case .conversionFailed: "The recording could not be prepared for transcription."
      case .httpStatus(let code, let body):
        body.isEmpty ? "Transcription failed (HTTP \(code))." : body
      case .emptyTranscript: "No speech was found in that recording."
      case .invalidResponse: "The transcription response was unreadable."
      }
    }
  }

  static func transcribe(
    audioURL: URL,
    provider: APIProvider,
    apiKey: String,
    prompt: String,
    languages: [String]
  ) async throws -> String {
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw ServiceError.missingAudio
    }

    let uploadURL = try makeUploadWAV(from: audioURL)
    defer { try? FileManager.default.removeItem(at: uploadURL) }

    switch provider {
    case .openAI:
      return try await transcribeOpenAI(
        fileURL: uploadURL,
        apiKey: apiKey,
        prompt: prompt,
        language: languages.first
      )
    case .openRouter:
      return try await transcribeOpenRouter(
        fileURL: uploadURL,
        apiKey: apiKey,
        prompt: prompt,
        language: languages.first
      )
    }
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
    append("Content-Type: audio/wav\r\n\r\n")
    body.append(try Data(contentsOf: fileURL))
    append("\r\n")

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
    append("gpt-4o-mini-transcribe\r\n")

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
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)
    try throwIfNeeded(data: data, response: response)
    return try decodeTranscript(data)
  }

  private static func transcribeOpenRouter(
    fileURL: URL,
    apiKey: String,
    prompt: String,
    language: String?
  ) async throws -> String {
    // Prefer OpenAI-compatible multipart so existing Whisper/transcribe models work.
    var body = Data()
    let boundary = "ListenToMe-\(UUID().uuidString)"

    func append(_ string: String) {
      body.append(Data(string.utf8))
    }

    append("--\(boundary)\r\n")
    append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
    )
    append("Content-Type: audio/wav\r\n\r\n")
    body.append(try Data(contentsOf: fileURL))
    append("\r\n")

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
    append("openai/whisper-large-v3\r\n")

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
      url: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    )
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue(
      "https://github.com/Hankyone/ListenToMe",
      forHTTPHeaderField: "HTTP-Referer"
    )
    request.setValue("ListenToMe", forHTTPHeaderField: "X-OpenRouter-Title")
    request.httpBody = body

    let (data, response) = try await URLSession.shared.data(for: request)
    try throwIfNeeded(data: data, response: response)
    return try decodeTranscript(data)
  }

  private static func throwIfNeeded(data: Data, response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw ServiceError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw ServiceError.httpStatus(http.statusCode, String(body.prefix(280)))
    }
  }

  private static func decodeTranscript(_ data: Data) throws -> String {
    guard
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = object["text"] as? String
    else {
      throw ServiceError.invalidResponse
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ServiceError.emptyTranscript }
    return trimmed
  }

  private static func makeUploadWAV(from sourceURL: URL) throws -> URL {
    let input = try AVAudioFile(forReading: sourceURL)
    let format = input.processingFormat
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("listentome-reprocess-\(UUID().uuidString)")
      .appendingPathExtension("wav")

    guard
      let output = try? AVAudioFile(
        forWriting: tempURL,
        settings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: format.sampleRate,
          AVNumberOfChannelsKey: format.channelCount,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
        ]
      )
    else {
      throw ServiceError.conversionFailed
    }

    let frameCount = AVAudioFrameCount(input.length)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: max(frameCount, 1)
      )
    else {
      throw ServiceError.conversionFailed
    }
    try input.read(into: buffer)
    try output.write(from: buffer)
    return tempURL
  }
}
