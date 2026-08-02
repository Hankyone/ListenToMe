<p align="center">
  <img src="Resources/AppIcon-v2.png" width="112" alt="ListenToMe app icon">
</p>

<h1 align="center">ListenToMe</h1>

<p align="center">
  Fast, native macOS dictation powered by OpenAI's GPT Live Transcribe.
</p>

ListenToMe lives in your menu bar. Press a shortcut anywhere, speak, and your
words land in the app you were using.

## Highlights

- Hold to talk or tap to toggle, with a fully customizable shortcut
- Live partial transcripts with custom words and language hints
- Focus-safe pasting with automatic clipboard fallback
- Local history with editable transcripts and replayable audio
- API key stored in macOS Keychain
- No accounts, analytics, cloud history, or extra model providers

## Run it

ListenToMe requires macOS 14 or newer, Xcode, and an OpenAI Platform API key.

```sh
./Scripts/package-app.sh
open dist/ListenToMe.app
```

Add your API key in **Setup**, then grant Microphone and Accessibility access
when macOS asks. OpenAI API usage is billed separately from ChatGPT and Codex
subscriptions.

## How it works

`Shortcut → microphone → GPT Live Transcribe → cursor`

Audio is streamed as 24 kHz PCM through an OpenAI Realtime transcription
session using [`gpt-live-transcribe`](https://developers.openai.com/api/docs/models/gpt-live-transcribe).
The app keeps transcript history and recorded audio locally on your Mac.

## Develop

```sh
./Scripts/test.sh
./Scripts/package-app.sh
```

This is an early MVP. Issues and focused pull requests are welcome.

## License

[MIT](LICENSE)
