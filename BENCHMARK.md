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
   the dictation key. Commit a range after at least 180 seconds plus 10 seconds
   of trailing all-zero PCM; any nonzero sample defers. A 310-second hard guard
   counts every admitted source byte in an item without an earlier qualifying
   pause, including silence. If any source follows that commit, reject the
   complete Realtime candidate and recover from the exact WAV. Limit unresolved
   backend items so the session cannot build an unbounded backlog.
3. On key release, stop capture, drain every queued PCM chunk, commit the final
   range, and verify exact ordered source coverage before assembling the raw
   transcript.
4. Send that complete transcript over the same Realtime connection for one
   polish request, then inject exactly one final result through accessibility.

If the Realtime path fails, the pipeline can then use
`POST /v1/audio/transcriptions`, followed by deterministic English cleanup or
unchanged non-English pass-through. There is no second model request. Cloud
delivery is atomic, so recovery always sends the exact complete WAV before
injecting one final result. This is serial recovery, not a request racing the
live WebSocket.

Cloud recording auto-finalizes after 300 seconds of wall time. The 310-second
source guard allows for scheduling delay without treating a hard acoustic cut
as a safe boundary for continued Realtime transcription. The Realtime-first
outer owner reserves a stable
`175 + 100 = 275` seconds for the maximum supported finish watchdog plus exact-
WAV recovery; the five-minute duration term raises the actual outer deadline
to its 300-second cap.

### Long-dictation evidence status

Paid tests on 2026-07-13 and 2026-07-14 used `gpt-realtime-2.1` with
`gpt-4o-mini-transcribe`:

| Case | Result | Claim boundary |
| --- | --- | --- |
| Forced 4 s hard seams | Failed fidelity: "April 15th" became "April 5th" despite exact byte coverage. | Non-silence hard cuts are unsafe; production falls back if source continues. |
| Historical `0.005` pause classifier, 15/3/0.3 s policy | Passed three exact ranges and preserved the meeting in raw and polished text. | Superseded scheduling evidence; not current-production acceptance. |
| Current zero-only meeting classifier | Passed one exact `0..<382400` item; raw and polished text retained two engineers, April 15th, and next week; 1.744307 s setup/send, 2.346383 s finish, 4.090776 s total. | Dated one-fixture current-policy result, not a general accuracy claim. |
| Accelerated 300 s exact-zero source | Passed ranges `0..<5760000` and `5760000..<9600000`; meeting and email remained ordered. | Predates threshold hardening; exact-zero scheduling is unchanged; not connection lifetime. |
| Real-time-paced 300 s exact-zero source | Passed the same ranges and fidelity checks; 321.715 s paced send work, 3.686 s finish, 325.401 s total. | Predates threshold hardening; dated connection-lifetime observation; the app timer is covered separately. |
| Direct exact-WAV batch | Preserved the meeting facts from a 382,444-byte canonical WAV in 1.247 s without model polish. | Endpoint acceptance only; deterministic tests prove pipeline routing. |

Production pause classification uses RMS threshold `0`: every sample in a
qualifying 20 ms window must be zero. The capture gate uses a centralized,
clamped `0.0005` minimum on the session-wide peak, but that does not prove an
individual nonzero window is silence. An intermediate `0.0005` Realtime
classifier was therefore also rejected. The old paid meeting artifact used
`0.005`; its recorded room energy now defers both former pause commits, so only
the final item is scheduled. The final
`conservativePauseClassification` paid run passed that one-item current service
path on 2026-07-14. Its source PCM SHA-256 is
`791f9712720a112e035252f3fdfc6ed0c9d783879e0223fa08845a8f5e17deba`;
the durable artifacts are `step10e-live-conservative-final.log` and
`step10e-live-evidence-conservative-final/conservative-pause-classification.json`.

The accelerated and paced sources generate their long silence as exact-zero
PCM, so their two deterministic boundary locations are unchanged by the
threshold correction even though both paid artifacts predate it. The paced
source SHA-256 is
`b0aa605b0bd246e803f53fe0810002e53dc4e7f151974a3292f8159d63de11eb`.
The retained live log records 2,348 wire chunks; that count is not part of the
JSON evidence schema.

The paced sender sleeps after each network send, so network overhead extends
its wall time beyond the source's 300 seconds. It proves the connection stayed
healthy for the full source duration, not that the provider adds 25 seconds of
post-dictation latency in normal capture.

The direct batch output retained two engineers and April 15th but did not match
the shared scenario's list punctuation. Its live test checks semantic facts and
records the formatting mismatch instead of treating punctuation as lost speech.

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
| Long dictation | Digital-zero-bounded Realtime commits; exact-WAV recovery after an unsafe hard cut; one final injection | Incremental rolling injection |
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

The long-dictation evidence above comes from the separately gated
`CloudDictationLiveHarnessTests`, not the latency benchmark suite. The live
tests require `FREEFLOW_TEST_OPENAI=1`, `FREEFLOW_TEST_OPENAI_LONG=1`, and an
`OPENAI_API_KEY`; `FREEFLOW_TEST_EVIDENCE_DIR` enables JSON evidence output.
