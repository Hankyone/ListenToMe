## ListenToMe 0.3.35

- Custom words can be edited in place (the old sheet didn’t take typing in a menu-bar app)
- One correct spelling can list several heard-as variants, comma-separated — e.g. Anouar with Anwar, Anuar
- Dictation audio is always kept in History when a take fails (live length limits, dropped connection, cancel). Reprocess from there — the recording is no longer thrown away
- Live prompt is compacted (spellings like Anouar (Anwar); Claude (cloud)) and still capped at OpenAI’s 1024-character limit, so a long app name no longer aborts the session
- Terminals (Ghostty, iTerm, Terminal, …) paste via System Events first — HID Cmd+V often never reaches the shell
