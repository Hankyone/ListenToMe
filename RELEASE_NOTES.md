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
