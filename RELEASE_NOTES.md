## ListenToMe 0.3.62

- After a successful paste, restore the previous clipboard instead of leaving the transcript there.
- A tap or hold with nothing said just ends — no error banner.
- Each microphone in the Setup priority list has its own input-volume slider.

## ListenToMe 0.3.61

- Setup input volume uses the same macOS Sound slider for every microphone, including USB mics like the SoloCast.
- File transcription stays in History with Gemini or OpenAI, and Setup no longer opens permission settings on its own.

## ListenToMe 0.3.60

- Make audio-file transcription a labeled action in History while keeping File menu and drag-and-drop access.
- Use Gemini 3.5 Transcribe or OpenAI GPT Transcribe for saved audio, matching the provider selected in Setup.
- Save imported audio to History before cloud processing, and compress and split long files so failures remain recoverable.
- Stop opening macOS permission settings automatically, and keep local builds signed with a stable Developer ID when one is available.

## ListenToMe 0.3.59

- Keep Gemini dictation running across the model's ten-minute connection rollover, then verify the final transcript from the saved recording.
- Preserve meaningful audio in History whenever a live connection or stop-state recovery cannot finish normally.

## ListenToMe 0.3.58

- Add a system input-volume slider for the active microphone in Setup, with clear handling for microphones that manage their own gain.

## ListenToMe 0.3.57

- Add Gemini 3.5 Transcribe for live dictation and imported audio files alongside OpenAI.
- Transcribe audio by dropping it into History, choosing it from History, or using the File menu.
- Keep languages and vocabulary provider-aware, and stream provider-native audio for lower latency.

## ListenToMe 0.3.56

- Tall overlay keeps the newest transcript lines in view and leaves the waveform centered while you talk.
- Paste skips the activate wait when the target app is already frontmost. Media pause skips apps that are not running. Stop waits less for a live transcript that is already on screen.

## ListenToMe 0.3.55

- Setup and the menu bar now show the installed version next to Check for Updates.

## ListenToMe 0.3.54

- Stop pasting the session prompt when a short take is re-pressed. Keep the next take recording instead of tearing it down mid-start.

## ListenToMe 0.3.53

- Hold, release, then press again starts the next take instead of playing another stop sound. The previous take still pastes in the background.

## ListenToMe 0.3.52

- Each take now records a latency trace (hotkey to paste) in Console and in `~/Library/Application Support/ListenToMe/latency.jsonl`, so we can see which step is slow before changing the pipeline.

## ListenToMe 0.3.51

- Setup and Words have less copy. Writing guidance no longer lists spoken revisions under the box
