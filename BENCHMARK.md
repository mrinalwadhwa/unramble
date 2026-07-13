# Benchmark

FreeFlow offers two dictation modes with different latency and privacy
profiles.

## OpenAI mode (default)

Audio streams directly from your Mac to OpenAI's Realtime API over a
persistent WebSocket. The model transcribes incrementally while you
speak, so by the time you release the key the transcript is already
done.

### How it works

1. Open a WebSocket to `wss://api.openai.com/v1/realtime` and configure
   it for transcription only. The first session pays a ~300 ms
   handshake; later sessions adopt a warm backup connection pre-opened
   in the background and skip the handshake entirely.
2. Stream 16 kHz PCM chunks resampled to 24 kHz while the user holds
   the dictation key.
3. On key release, commit the audio buffer and wait for the transcript.
4. Run the raw transcript through the local polish pipeline:
   deterministic regex substitution → `isClean` skip heuristic →
   (optional) a single `gpt-4.1-nano` chat completion for cleanup.
5. Inject the polished text into the target app via the accessibility
   API.

A batch fallback (`POST /v1/audio/transcriptions` with the full WAV)
runs in parallel and catches the case where the WebSocket errors out
mid-session. Whichever path finishes first wins.

### Real-world numbers

Measured across 42 successful real-speech dictations on an M4 MacBook
Pro. Pipeline total is key release → polished text visible at cursor.

| Phase | Typical | Notes |
|-------|---------|-------|
| WebSocket handshake | ~300 ms | Cold start only; warm backup makes this 0 ms |
| First transcript delta | 250–550 ms | After audio commit |
| Transcript complete | 280 ms–1.27 s | Scales sub-linearly with audio length |
| Polish (skip path) | < 3 ms | 83% of dictations skip LLM polish entirely |
| Polish (LLM path) | 320 ms–780 ms | `gpt-4.1-nano`, 17% of dictations |
| Text injection | ~70 ms | Via accessibility API |

**End-to-end totals:**

| Metric | Latency |
|--------|---------|
| min | 0.34 s |
| p50 | 0.55 s |
| p95 | 2.16 s |
| max | 2.89 s |

Warm backup adoption rate: 91% of non-cold sessions (39/43). The
background pre-open task keeps up with normal dictation pace, so most
sessions see zero connection setup time.

### Polish skip rate

The `isClean` heuristic checks whether the transcript already starts
with a capital letter, ends with sentence punctuation, contains no
filler words, and has no repeated phrases. When these conditions are
met, the LLM polish step is skipped entirely and the transcript goes
straight to injection. In real-world usage, **83% of dictations** take
this fast path.

## On-device mode

Local mode transcribes with a Core ML speech model and polishes with a
fine-tuned Qwen model running through MLX. It prefers Nemotron when that
model is installed and otherwise uses Parakeet. No network calls or API
key are required, and audio never leaves the Mac.

### How it works

1. Prefer Nemotron when its model is installed; otherwise load the
   packaged Parakeet model.
2. For Nemotron, create one streaming state and feed only newly recorded
   16 kHz mono PCM during each cycle. Parakeet instead retranscribes the
   accumulated audio on each cycle.
3. Polish and inject sentences after they stabilize across consecutive
   recognition cycles, leaving the changing tail uncommitted.
4. On key release, finish recognition, polish the remaining tail with
   Qwen, and inject it after the previously committed text.

### Tradeoffs

| | OpenAI mode | On-device mode |
|---|---|---|
| Requires API key | Yes | No |
| Network required | Yes | No |
| Audio leaves Mac | Yes (to OpenAI) | No |
| macOS requirement | 14+ | 14+ on Apple Silicon |
| Accuracy | Large cloud model | Nemotron or Parakeet 0.6B |
| Latency | ~0.55 s p50 | Depends on hardware |
| Long dictation | Chunked at 300 s | Incremental rolling injection |
| Cost | OpenAI API usage | Free |

## Running the benchmarks

Gated benchmark suites live in
`FreeFlowKit/Tests/FreeFlowKitTests/OpenAIRealtimeBenchmarkTests.swift`:

- `bench: single session breakdown` — one full session, prints
  startStreaming / sendAudio / finishStreaming / total.
- `bench: 5 sequential sessions` — min/p50/mean/max across 5
  back-to-back sessions.
- `bench: 5 sessions with 1.5 s gap (warm backup)` — five sessions
  with a realistic gap so the warm-backup task can pre-open connections.

```bash
OPENAI_API_KEY=sk-... \
FREEFLOW_TEST_OPENAI=1 \
FREEFLOW_TEST_OPENAI_BENCH=1 \
swift test --filter OpenAIRealtimeBenchmark 2>&1 | tail -20
```

These benchmarks use silent PCM, which is a worst case for
`finishStreaming` (no speech content to transcribe). Real-speech latency
is typically faster because the model processes audio incrementally
during recording.
