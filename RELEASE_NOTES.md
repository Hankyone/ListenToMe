## ListenToMe 0.3.41

- OpenAI only: removed the OpenRouter provider and its batch-only Whisper path. Dictation always uses live `gpt-live-transcribe`; file fallback and History reprocess still use `gpt-4o-mini-transcribe`
