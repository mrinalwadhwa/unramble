# Benchmark

FreeFlow offers two dictation modes with different latency and privacy
profiles.

## OpenAI mode (default)

Audio streams directly from your Mac to OpenAI's Realtime API over a
persistent WebSocket. The model transcribes incrementally while you
speak, so much of the audio processing is already underway when you
release the key.

### How it works

1. Open a WebSocket to `wss://api.openai.com/v1/realtime` and configure
   its transcription model and polish instructions. The first session pays a
   ~300 ms handshake; later sessions adopt a warm backup connection pre-opened
   in the background and skip the handshake entirely.
2. Stream 16 kHz PCM chunks resampled to 24 kHz while the user holds
   the dictation key. Commit bounded source ranges after 180 seconds plus 10
   seconds of trailing silence, or at the 300-second hard boundary. Limit
   unresolved backend items so the session cannot build an unbounded backlog.
3. On key release, stop capture, drain every queued PCM chunk, commit the final
   range, and verify exact ordered source coverage before assembling the raw
   transcript.
4. Send that complete transcript over the same Realtime connection for one
   polish request, then inject exactly one final result through accessibility.

If the Realtime path fails, the pipeline can then use
`POST /v1/audio/transcriptions` and polish that transcript through the
chat-completion path. Cloud delivery is atomic, so recovery always sends the
exact complete WAV before injecting one final result. This is serial recovery,
not a request racing the live WebSocket.

### Historical baseline

The following 42-session real-speech baseline was measured on an M4 MacBook
Pro using the previous skip-or-chat polish path. It has not been rerun against
the production Realtime-response polish path, so it is retained for comparison
rather than presented as current performance. Pipeline total is key release →
polished text visible at cursor.

| Phase | Typical | Notes |
|-------|---------|-------|
| WebSocket handshake | ~300 ms | Cold start only; warm backup makes this 0 ms |
| First transcript delta | 250–550 ms | After audio commit |
| Transcript complete | 280 ms–1.27 s | Scales sub-linearly with audio length |
| Polish (skip path) | < 3 ms | Previous deterministic skip path |
| Polish (chat path) | 320 ms–780 ms | Previous separate chat request |
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

## On-device mode

Local mode transcribes with the required Nemotron 0.6B Core ML model and
polishes with a fine-tuned Qwen model running through MLX. Both models are
loaded from packaged assets, with a manually provisioned Application Support
fallback. Builds and archives verify the packaged model pack against its pinned
manifest without network access; runtime loading fails explicitly when the
resolved assets are missing or invalid. No API key is required, and audio never
leaves the Mac.

### How it works

1. Resolve packaged Nemotron and Qwen assets, or a manually provisioned
   Application Support fallback when a packaged directory is unavailable.
   Build and archive verify the packaged model pack; runtime preload fails
   explicitly for unresolved or invalid assets.
2. Create one Nemotron recognition session and feed only newly recorded
   16 kHz mono PCM during each cycle.
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
| Accuracy | Large cloud model | Nemotron 0.6B |
| Latency | Pending rebenchmark (historical p50: 0.55 s) | Depends on hardware |
| Long dictation | Bounded backend commits; one final injection | Incremental rolling injection |
| Cost | OpenAI API usage | Free |

## Running the benchmarks

Gated benchmark suites live in
`FreeFlowKit/Tests/FreeFlowKitTests/OpenAIStreamingBenchmarkTests.swift`:

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
swift test --filter OpenAIStreamingBenchmark 2>&1 | tail -20
```

These benchmarks use silent PCM, which is a worst case for
`finishStreaming` (no speech content to transcribe). Real-speech latency
is typically faster because the model processes audio incrementally
during recording.
