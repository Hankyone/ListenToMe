## ListenToMe 0.3.26

- Pre-connect the OpenAI realtime session while idle so hotkey isn’t waiting on TLS + handshake
- Keep the mic graph warm between takes — waveform should move immediately
- After each take, re-arm mic + socket for the next one
