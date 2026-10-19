# Bengali language handling

Both inference paths previously started with `language=auto`. Only transcription
with mostly Devanagari output retried in Bengali; an incorrect English result
passed through, and translation did not retry. This is a plausible contributor
to the reported unrelated translations of “আম্মু যায় নাই আজকে”, not a proven
diagnosis without the original recording.

Settings now defaults the spoken language to Bengali (`bn`) for both modes.
English (`en`) and Auto-detect (`auto`) remain available. Each HTTP request sends
the selected source language and an explicit translation flag; CLI fallback and
server startup use the same selection. Translation still uses multilingual
medium; transcription still uses large-v3-turbo. No model downloads, vocabulary
prompts, phrase replacement, or second translation stage are added.

The HTTP `language` and `translate` fields are supported by
[whisper.cpp's server](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/server.cpp).
Whisper's [model guidance](https://github.com/openai/whisper#command-line-usage)
recommends a multilingual model such as medium for translation; turbo is not
trained for translation.

## Automated checks

Run `swift test` and `swift build -c release` on macOS 14 or later.
Tests cover language selection, HTTP multipart requests, mode/model CLI and
server arguments, the Auto transcription retry, and HTTP failure handling.
Responses are mocked: the Bengali and English strings are transport fixtures,
not evidence of recognition or translation accuracy.

## Recorded-speech checklist

Use the same recording for before/after comparisons, ideally 16 kHz mono PCM
WAV. Record app commit, macOS/chip, whisper.cpp version, model file, spoken
language, inference path, elapsed time, and unedited output. Keep audio local.

| Input | Transcription check | Translation check |
|---|---|---|
| আম্মু যায় নাই আজকে | Preserve subject, negation, and today | “Mom didn't go today” or equivalent; no invented destination |
| আম্মু গেছে আজকে | Distinguish positive from negative | “Mom went today” or equivalent |
| আমি আজকে বাসায় যাব না | Preserve first person and negation | “I won't go home today” or equivalent |
| আমি Node.js দিয়ে API বানাচ্ছি | Inspect technical names without forcing their spelling | Preserve Node.js and API meaning |
| English speech with English selected | English transcript | English meaning retained |
| English speech with Auto-detect selected | English transcript | English meaning retained |

For each mode, test a warm server and CLI fallback (without a server). Change
the language while a server is warm and check the next request. Repeat short
clips several times with natural Bangladeshi pronunciation. Check silence and
background noise for hallucinations. Human review is needed for dialect,
code-switching, and negation; transport tests cannot measure those qualities.

The original failing audio is not included in this repository. A passing build
or mocked test suite does not establish that the reported mistranslation is
resolved, or benchmark model accuracy or latency.
