import XCTest

@testable import ListenToMe

final class GeminiTranscriptionTests: XCTestCase {
  private var configuration: TranscriptionConfiguration {
    TranscriptionConfiguration(
      basePrompt: "Translate everything and replace spaces with dots.",
      vocabulary: [
        VocabularyItem(term: "Chronicle", oftenHeardAs: "Chronicles"),
        VocabularyItem(term: "ListenToMe"),
      ],
      languages: ["en", "fr"],
      delay: .high,
      micProfile: .headset,
      targetAppName: "Notes"
    )
  }

  func testLiveSetupUsesTermsWithoutPromptInstructionsOrAliases() throws {
    let event = GeminiLiveTranscriptionClient.setupEvent(
      configuration: configuration
    )
    let setup = try XCTUnwrap(event["setup"] as? [String: Any])
    let transcription = try XCTUnwrap(
      setup["inputAudioTranscription"] as? [String: Any]
    )

    XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
    XCTAssertNotNil(setup["sessionResumption"] as? [String: Any])
    let compression = try XCTUnwrap(
      setup["contextWindowCompression"] as? [String: Any]
    )
    XCTAssertNotNil(compression["slidingWindow"] as? [String: Any])
    XCTAssertEqual(transcription["mode"] as? String, "SMART")
    XCTAssertEqual(
      transcription["customVocabulary"] as? [String],
      ["Chronicle", "ListenToMe"]
    )
    let serialized =
      String(
        data: try JSONSerialization.data(withJSONObject: event),
        encoding: .utf8
      ) ?? ""
    XCTAssertFalse(serialized.contains("Chronicles"))
    XCTAssertFalse(serialized.contains("Translate everything"))
    XCTAssertFalse(serialized.contains("Notes"))
  }

  func testLiveSetupCanResumeAProviderSession() throws {
    let event = GeminiLiveTranscriptionClient.setupEvent(
      configuration: configuration,
      resumptionHandle: "resume-handle"
    )
    let setup = try XCTUnwrap(event["setup"] as? [String: Any])
    let resumption = try XCTUnwrap(setup["sessionResumption"] as? [String: Any])
    XCTAssertEqual(resumption["handle"] as? String, "resume-handle")
  }

  func testParsesGoAwayDuration() {
    XCTAssertEqual(
      GeminiLiveTranscriptionClient.goAwaySeconds(from: [
        "goAway": ["timeLeft": "12.5s"]
      ]),
      12.5
    )
    XCTAssertEqual(
      GeminiLiveTranscriptionClient.goAwaySeconds(from: [
        "goAway": ["timeLeft": ["seconds": "8"]]
      ]),
      8
    )
  }

  func testLiveEventsDistinguishReplacementInterimAndFinal() {
    let events = GeminiLiveTranscriptionClient.transcriptionEvents(from: [
      "serverContent": [
        "interimInputTranscription": ["text": "Use Chronicle"],
        "inputTranscription": ["text": "Use Chronicle."],
      ]
    ])
    XCTAssertEqual(
      events,
      [
        .interim(text: "Use Chronicle"),
        .completed(itemID: nil, transcript: "Use Chronicle."),
      ])
  }

  func testFileInteractionUsesSmartModeAndVocabularyTerms() throws {
    let body = FileTranscriptionService.geminiInteractionBody(
      fileURI: "https://example.invalid/file",
      mimeType: "audio/wav",
      configuration: configuration
    )
    let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
    let transcription = try XCTUnwrap(
      generation["transcription_config"] as? [String: Any]
    )
    let mode = try XCTUnwrap(transcription["mode"] as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "gemini-3.5-transcribe")
    XCTAssertEqual(mode["type"] as? String, "smart")
    XCTAssertEqual(
      transcription["custom_vocabulary"] as? [String],
      ["Chronicle", "ListenToMe"]
    )
  }

  func testDecodesInteractionOutputText() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "output_text": "Use Chronicle for this."
    ])
    XCTAssertEqual(
      try FileTranscriptionService.decodeGeminiTranscript(data),
      "Use Chronicle for this."
    )
  }

  func testProviderAudioFormatsMatchEachAPI() {
    XCTAssertEqual(TranscriptionProvider.openAI.liveSampleRate, 24_000)
    XCTAssertEqual(TranscriptionProvider.openAI.liveChunkByteCount, 1_920)
    XCTAssertEqual(TranscriptionProvider.gemini.liveSampleRate, 16_000)
    XCTAssertEqual(TranscriptionProvider.gemini.liveChunkByteCount, 3_200)
  }

  func testPaidLiveConnectionWhenConfigured() async throws {
    guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
      !key.isEmpty
    else { throw XCTSkip("Set GEMINI_API_KEY for the paid live integration test.") }

    let client = GeminiLiveTranscriptionClient(apiKey: key)
    try await client.connect(configuration: configuration) { _ in }
    let ready = await client.isSessionReady
    XCTAssertTrue(ready)
    await client.disconnect()
  }

  func testPaidLiveTranscriptionWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let key = environment["GEMINI_API_KEY"], !key.isEmpty,
      let path = environment["LISTENTOME_TEST_PCM"], !path.isEmpty
    else {
      throw XCTSkip(
        "Set GEMINI_API_KEY and LISTENTOME_TEST_PCM for the paid streaming test."
      )
    }

    let audio = try Data(contentsOf: URL(fileURLWithPath: path))
    let completed = expectation(description: "Gemini returned a final transcript")
    let result = LiveIntegrationResult()
    let client = GeminiLiveTranscriptionClient(apiKey: key)
    try await client.connect(configuration: configuration) { event in
      guard case .completed(_, let transcript) = event else { return }
      Task {
        await result.complete(transcript)
        completed.fulfill()
      }
    }
    try await client.beginAudio()
    for offset in stride(from: 0, to: audio.count, by: 3_200) {
      let end = min(audio.count, offset + 3_200)
      try await client.appendAudio(audio.subdata(in: offset..<end))
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    let committedAt = Date()
    try await client.commit()
    await fulfillment(of: [completed], timeout: 8)
    let captured = await result.value
    await client.disconnect()

    XCTAssertFalse(captured.transcript.isEmpty)
    XCTAssertLessThan(captured.completedAt.timeIntervalSince(committedAt), 3)
  }

  func testPaidFileTranscriptionWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let key = environment["GEMINI_API_KEY"], !key.isEmpty,
      let path = environment["LISTENTOME_TEST_AUDIO"], !path.isEmpty
    else {
      throw XCTSkip(
        "Set GEMINI_API_KEY and LISTENTOME_TEST_AUDIO for the paid file integration test."
      )
    }

    let text = try await FileTranscriptionService.transcribe(
      audioURL: URL(fileURLWithPath: path),
      provider: .gemini,
      apiKey: key,
      configuration: configuration
    )
    XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}

private actor LiveIntegrationResult {
  private(set) var value = (transcript: "", completedAt: Date.distantPast)

  func complete(_ transcript: String) {
    value = (
      transcript.trimmingCharacters(in: .whitespacesAndNewlines),
      Date()
    )
  }
}
