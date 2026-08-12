import Foundation

/// Stop-time language-model pass. Live STT is literal; this is what actually
/// applies spoken self-corrections, pauses and all.
enum TranscriptPolishService {
  static let timeout: TimeInterval = 3

  static func polish(
    transcript: String,
    provider: APIProvider,
    apiKey: String,
    guidance: String,
    vocabulary: [VocabularyItem]
  ) async -> String? {
    let original = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !original.isEmpty, !apiKey.isEmpty else { return nil }

    do {
      let data = try await postChat(
        provider: provider,
        apiKey: apiKey,
        messages: [
          ["role": "system", "content": systemPrompt(guidance: guidance, vocabulary: vocabulary)],
          ["role": "user", "content": original],
        ]
      )
      guard let candidate = decodeContent(data),
        shouldAccept(original: original, candidate: candidate)
      else {
        return nil
      }
      return candidate
    } catch {
      return nil
    }
  }

  static func shouldAccept(original: String, candidate: String) -> Bool {
    let polished = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !polished.isEmpty else { return false }
    let limit = max(original.count * 3, original.count + 80)
    return polished.count <= limit
  }

  static func systemPrompt(
    guidance: String,
    vocabulary: [VocabularyItem]
  ) -> String {
    var parts: [String] = [
      """
      You clean a live speech-to-text transcript before it is pasted. Output only the cleaned text — no quotes, no preamble.

      Spoken self-corrections are normal speech. Pauses, commas, and wording vary. Apply the speaker's intent:
      - "a trip to Toronto, correction, Montreal" → "a trip to Montreal"
      - "a trip to Montreal, correction to Toronto" → "a trip to Toronto"
      - "meet me at 5, I mean 6" → "meet me at 6"
      - "hello world scratch that" → drop the last phrase
      Replace the discarded words with the restatement. Remove the cue. Do not require a particular comma or pause pattern.

      Keep the speaker's wording. Do not paraphrase or invent. Light punctuation and capitalization. Strip filler (um, uh, er, you know).
      """
      .trimmingCharacters(in: .whitespacesAndNewlines),
    ]

    let extra = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
    if !extra.isEmpty {
      parts.append(extra)
    }

    let terms = vocabulary.map(\.term).filter { !$0.isEmpty }
    if !terms.isEmpty {
      parts.append("Prefer these spellings: \(terms.joined(separator: ", ")).")
    }

    return parts.joined(separator: "\n\n")
  }

  private static func postChat(
    provider: APIProvider,
    apiKey: String,
    messages: [[String: String]]
  ) async throws -> Data {
    let url: URL
    let model: String
    switch provider {
    case .openAI:
      url = URL(string: "https://api.openai.com/v1/chat/completions")!
      model = "gpt-4o-mini"
    case .openRouter:
      url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
      model = "openai/gpt-4o-mini"
    }

    let body: [String: Any] = [
      "model": model,
      "temperature": 0,
      "max_tokens": 800,
      "messages": messages,
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if provider == .openRouter {
      request.setValue(
        "https://github.com/Hankyone/ListenToMe",
        forHTTPHeaderField: "HTTP-Referer"
      )
      request.setValue("ListenToMe", forHTTPHeaderField: "X-OpenRouter-Title")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else {
      throw URLError(.badServerResponse)
    }
    return data
  }

  static func decodeContent(_ data: Data) -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = object["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String
    else {
      return nil
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
      return trimmed.isEmpty ? nil : trimmed
    }
    return String(trimmed.dropFirst().dropLast())
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
