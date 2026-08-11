## ListenToMe 0.3.28

- Fix frozen overlay: media pause AppleScript no longer blocks the main thread (was freezing timer + waveform for 5–8s every take)
- Timer ticks from hotkey via TimelineView; mic warm-up awaited at launch so the first take promotes instantly
- Standby OpenAI socket and live audio send run off the main actor
