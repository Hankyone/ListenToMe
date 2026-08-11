## ListenToMe 0.3.24

- Hotkey starts capture like Handy/VoiceInk: overlay + mic first, no permission waits on the critical path
- Warm microphone keep-alive (~30s) so back-to-back takes aren’t paying cold HAL spin-up
- Live transcript no longer races through buffered audio after the websocket connects
