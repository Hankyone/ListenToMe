## ListenToMe 0.3.79

- Fixed a jam where the app kept recording and the push-to-talk key went dead: when transcription finished text while a take was ending, the microphone engine could be left running forever behind an already-delivered take. The mic is now stopped by whichever path finishes first.
- Escape now always cancels: it stops a live mic even when a previous end got stuck halfway, instead of only playing the sound.

## ListenToMe 0.3.78

- The push-to-talk key can no longer go dead. If the app ever loses the key-up event, the next press is treated as a fresh press instead of being swallowed as a key repeat, so a stuck take can always be ended.
- A take that somehow never ends now force-recovers after ten minutes instead of holding the app and the hotkey hostage.

## ListenToMe 0.3.77

- The mic opens the moment you push to talk. A video pause costs a fixed 200 ms, never the multi-second wait for the sound to drain.
- An already-paused video is never touched. The play/pause key now goes out only when the Now Playing session confirms media is actually playing, so pressing push-to-talk can never start playback that was not playing.
- Resume only fires when the video or song is still paused, so a restart you did by hand mid-take is never paused again.
- Media pause is scoped to each take: stale or duplicate cleanup from an aborted take can no longer toggle playback, and audio from one take can never leak into another.

## ListenToMe 0.3.76

- Media no longer starts playing again mid-take: a slow-to-pause video could look like a failed pause and get toggled back on. Browsers and web apps now get only the play/pause key, never a double command.
- The last word of a video no longer leaks into your transcript. On displays that cannot be muted (like HDMI monitors), the mic now waits until playback has actually stopped.
- Dictating during a Zoom, Meet, Teams, or FaceTime call no longer touches media playback.

## ListenToMe 0.3.75

- Pause and resume your music or video around a take again. Playback detection now watches which apps are actually making sound instead of asking Now Playing, which no longer answers apps on recent macOS. You may see a one-time prompt to let ListenToMe control Music or Spotify.

## ListenToMe 0.3.74

- Resume your music or video when you stop dictating. On the first take after launch it could stay paused forever.

## ListenToMe 0.3.73

- Pause playing media again, including YouTube in a browser. The last version skipped pause when the browser did not report Now Playing.

## ListenToMe 0.3.72

- If a video or song is playing, wait until it is paused before the microphone opens. If nothing is playing, start listening immediately.

## ListenToMe 0.3.71

- Start the microphone immediately. Pausing a video no longer delays the start of a take when nothing is playing.

## ListenToMe 0.3.70

- Keep a long take listening when the live model sends a finished-text snapshot. Paste only after you stop, so the overlay does not go blank mid-sentence.

## ListenToMe 0.3.69

- After pausing a playing video or song, wait a beat before the microphone so the first word is yours, not the video.

## ListenToMe 0.3.68

- Continue mid-written sentences without capitalizing safe common words, while preserving names, acronyms, custom vocabulary, and new sentence capitalization.
- Detect prose, search, naming, and code fields locally so search queries and names do not end with unwanted sentence punctuation.
- Add remembered per-field formatting overrides under the menu bar's Formatting submenu.

## ListenToMe 0.3.67

- Add missing spaces where dictated text meets existing text at the caret, while avoiding double spaces and spaces before punctuation.

## ListenToMe 0.3.66

- Pause the video or song that is actually playing when you start dictating, including YouTube in a browser, then start it again when you stop. Already-paused media stays paused.

## ListenToMe 0.3.65

- If a video or song was already paused, leave it paused after you stop dictating instead of starting it.

## ListenToMe 0.3.64

- Rebuild the microphone after sleep or docking so a USB mic like the SoloCast is live again instead of a silent stale graph.
- Pause Now Playing media (YouTube in a browser, Music, Spotify) when a take starts, and mute the current output device.

## ListenToMe 0.3.63

- Keep the microphone open for 400ms after you release the key so the last words still make it into the transcript.

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
