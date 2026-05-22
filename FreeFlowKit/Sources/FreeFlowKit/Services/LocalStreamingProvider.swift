import Foundation

/// On-device streaming dictation with incremental transcription.
///
/// Accumulate PCM audio during recording. Every `cycleInterval`
/// seconds, re-transcribe accumulated audio with the STT engine
/// and polish new complete sentences in the background. By the
/// time the user releases the key, most text is already polished
/// and only the tail needs processing.
///
/// On key release, the final transcript is authoritative. Cached
/// polish is reused only when the corresponding raw sentences
/// match the final transcript exactly. From the first mismatch
/// onward, everything is re-polished as one batch.
public final class LocalStreamingProvider: StreamingDictationProviding,
    @unchecked Sendable
{

    // MARK: - Configuration

    private let sttEngine: any LocalSTTEngine
    private let polishChatClient: (any PolishChatClient)?
    private let polishModel: String
    private let cycleInterval: TimeInterval

    // MARK: - State (guarded by lock)

    private let lock = NSLock()
    private var accumulatedAudio = Data()
    private var currentContext: AppContext = .empty

    /// Each entry is a (rawSentences, polishedText) pair from one
    /// background cycle. rawSentences is the exact text the cycle
    /// saw before polishing — used to verify against the final
    /// transcript.
    private var cache: [(raw: [String], polished: String)] = []

    private var finishing = false
    private var backgroundTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        sttEngine: any LocalSTTEngine,
        polishChatClient: (any PolishChatClient)?,
        polishModel: String = PolishPipeline.polishModel,
        cycleInterval: TimeInterval = 10
    ) {
        self.sttEngine = sttEngine
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
        self.cycleInterval = cycleInterval
    }

    // MARK: - StreamingDictationProviding

    public var uncommittedAudioDuration: TimeInterval {
        let bytes = lock.withLock { accumulatedAudio.count }
        return Double(bytes) / 32_000.0
    }

    public func startStreaming(
        context: AppContext, language: String?, micProximity: MicProximity
    ) async throws {
        if !sttEngine.isReady {
            Log.debug("[LocalStreaming] Loading STT engine \(sttEngine.name)")
            try await sttEngine.load()
            Log.debug("[LocalStreaming] STT engine loaded")
        }
        lock.withLock {
            accumulatedAudio = Data()
            currentContext = context
            cache = []
            finishing = false
        }

        backgroundTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runBackgroundCycles()
        }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        lock.withLock { accumulatedAudio.append(pcmData) }
    }

    public func finishStreaming() async throws -> String {
        lock.withLock { finishing = true }
        backgroundTask?.cancel()
        await backgroundTask?.value
        backgroundTask = nil

        let (audio, context, cachedEntries) = lock.withLock {
            let d = accumulatedAudio
            accumulatedAudio = Data()
            let result = (d, currentContext, cache)
            cache = []
            return result
        }

        guard !audio.isEmpty else {
            Log.debug("[LocalStreaming] No audio accumulated")
            return ""
        }

        // Final authoritative transcription.
        let wav = WAVEncoder.encode(
            pcmData: audio, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let sttStart = CFAbsoluteTimeGetCurrent()
        let raw = try await sttEngine.transcribe(audio: wav)
        let sttElapsed = CFAbsoluteTimeGetCurrent() - sttStart
        Log.debug("[LocalStreaming] Final transcription: '\(raw)' (stt=\(String(format: "%.2f", sttElapsed))s)")

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let finalSentences = splitIntoSentences(trimmed)

        // Verify cache against the final transcript. Later cache
        // entries had more audio context and are more likely to match.
        // Find the first cache entry (scanning forward) where ALL its
        // sentences match the final transcript. Everything before it
        // is re-polished. Everything from it onward uses cached polish.
        //
        // Example: 5 cache entries covering sentences 0-1, 2-4, 5-7, 8-9, 10-11
        // Entry 0 (t=10s): sentence 1 differs → skip
        // Entry 1 (t=20s): sentences 2-4 all match → use entries 1-4
        // Result: re-polish sentences 0-4 from final, use cache for 5-11

        // Find the longest contiguous run of matching entries,
        // scanning forward. Early entries may mismatch (Parakeet
        // revision with partial audio). Later entries may also
        // mismatch if Parakeet extended a sentence boundary.
        // Only use entries that are verified against the final.
        var firstMatchEntry = -1
        var lastMatchEntry = -1
        var sentenceOffset = 0
        for (entryIdx, entry) in cachedEntries.enumerated() {
            let entryEnd = sentenceOffset + entry.raw.count
            if entryEnd <= finalSentences.count {
                let finalSlice = Array(finalSentences[sentenceOffset..<entryEnd])
                if entrySentencesMatch(cached: entry.raw, final: finalSlice) {
                    if firstMatchEntry < 0 {
                        firstMatchEntry = entryIdx
                    }
                    lastMatchEntry = entryIdx
                } else if firstMatchEntry >= 0 {
                    // Contiguous run broken — stop here.
                    break
                }
            } else {
                // Cache extends beyond final sentence count — stop.
                break
            }
            sentenceOffset = entryEnd
        }

        if firstMatchEntry >= 0 {
            let matchedEntries = Array(cachedEntries[firstMatchEntry...lastMatchEntry])
            let cachedPolished = matchedEntries.map { $0.polished }.joined(separator: " ")
            let cachedSentenceCount = matchedEntries.flatMap { $0.raw }.count

            // Head: sentences before the first match.
            var firstMatchSentence = 0
            for i in 0..<firstMatchEntry {
                firstMatchSentence += cachedEntries[i].raw.count
            }
            let headSentences = Array(finalSentences[0..<firstMatchSentence])
            let head = headSentences.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            // Tail: sentences after the last verified entry.
            let cachedEnd = firstMatchSentence + cachedSentenceCount
            let tailSentences = cachedEnd < finalSentences.count
                ? Array(finalSentences[cachedEnd...])
                : []
            let tail = tailSentences.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            let polishStart = CFAbsoluteTimeGetCurrent()

            // Polish head (if any) and tail (if any).
            var parts: [String] = []
            if !head.isEmpty {
                let polishedHead = await polishWithPreceding(
                    head, preceding: "", context: context)
                parts.append(polishedHead)
            }
            parts.append(cachedPolished)
            if !tail.isEmpty {
                let preceding = parts.joined(separator: " ")
                let polishedTail = await polishWithPreceding(
                    tail, preceding: preceding, context: context)
                parts.append(polishedTail)
            }

            let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart
            let result = parts.joined(separator: " ")
            Log.debug("[LocalStreaming] Incremental (head=\(headSentences.count) cached=\(cachedSentenceCount) tail=\(tailSentences.count) stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")
            return result
        }

        // No cache entry matched — polish everything.
        let polishStart = CFAbsoluteTimeGetCurrent()
        let result = await polishWithPreceding(
            trimmed, preceding: "", context: context)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart
        Log.debug("[LocalStreaming] Full polish (\(finalSentences.count) sentences, stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")
        return result
    }

    public func cancelStreaming() async {
        lock.withLock {
            accumulatedAudio = Data()
            finishing = true
        }
        backgroundTask?.cancel()
        await backgroundTask?.value
        backgroundTask = nil
    }

    // MARK: - Background Cycles

    private func runBackgroundCycles() async {
        try? await Task.sleep(nanoseconds: UInt64(cycleInterval * 1_000_000_000))

        while !Task.isCancelled {
            let isFinishing = lock.withLock { finishing }
            if isFinishing { break }

            await runOneCycle()

            try? await Task.sleep(nanoseconds: UInt64(cycleInterval * 1_000_000_000))
        }
    }

    private func runOneCycle() async {
        let (audio, context, cachedSentenceCount) = lock.withLock {
            let count = cache.flatMap({ $0.raw }).count
            return (accumulatedAudio, currentContext, count)
        }

        guard audio.count > 16_000 else { return }

        let wav = WAVEncoder.encode(
            pcmData: audio, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let sttStart = CFAbsoluteTimeGetCurrent()
        guard let raw = try? await sttEngine.transcribe(audio: wav) else { return }
        let sttElapsed = CFAbsoluteTimeGetCurrent() - sttStart
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Log.debug("[LocalStreaming] Background STT: '\(trimmed)' (stt=\(String(format: "%.2f", sttElapsed))s)")

        let allSentences = splitIntoSentences(trimmed)

        // Count complete sentences (last may be incomplete if text
        // doesn't end with punctuation).
        let completeCount: Int
        if PolishPipeline.endsAtSentenceBoundary(trimmed) {
            completeCount = allSentences.count
        } else {
            completeCount = max(0, allSentences.count - 1)
        }

        guard completeCount > cachedSentenceCount else {
            Log.debug("[LocalStreaming] Background: no new sentences (have=\(completeCount), cached=\(cachedSentenceCount))")
            return
        }

        let isFinishing = lock.withLock { finishing }
        if isFinishing { return }

        let newSentences = Array(allSentences[cachedSentenceCount..<completeCount])
        let newText = newSentences.joined(separator: " ")

        let polishStart = CFAbsoluteTimeGetCurrent()
        let precedingPolished = lock.withLock {
            cache.map { $0.polished }.joined(separator: " ")
        }
        let polished = await polishWithPreceding(
            newText, preceding: precedingPolished, context: context)
        let polishElapsed = CFAbsoluteTimeGetCurrent() - polishStart

        lock.withLock {
            cache.append((raw: newSentences, polished: polished))
        }

        Log.debug("[LocalStreaming] Background: +\(newSentences.count) sentences (total=\(completeCount), stt=\(String(format: "%.2f", sttElapsed))s polish=\(String(format: "%.2f", polishElapsed))s)")
    }

    // MARK: - Cache Verification

    /// Compare cached raw sentences against the final transcript.
    /// Return the number of leading sentences that match after
    /// normalization. Ignores capitalization, punctuation, and
    /// extra whitespace so minor Parakeet revisions don't
    /// invalidate the cache.
    /// Check whether all sentences in a cache entry match the
    /// corresponding sentences in the final transcript.
    private func entrySentencesMatch(
        cached: [String], final: [String]
    ) -> Bool {
        guard cached.count == final.count else { return false }
        for i in 0..<cached.count {
            if normalizeForComparison(cached[i])
                != normalizeForComparison(final[i]) {
                Log.debug("[LocalStreaming] Mismatch at sentence \(i):")
                Log.debug("  cached: \(cached[i])")
                Log.debug("  final:  \(final[i])")
                return false
            }
        }
        return true
    }

    /// Strip punctuation, lowercase, and collapse whitespace for
    /// fuzzy sentence comparison.
    private func normalizeForComparison(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.whitespaces.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map { String($0) }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    // MARK: - Polishing

    private func polishWithPreceding(
        _ raw: String, preceding: String, context: AppContext
    ) async -> String {
        let casual = PolishPipeline.toneLabel(for: context.bundleID) == "casual"
        let substituted = PolishPipeline.substituteDictatedPunctuation(
            raw, casual: casual,
            precedingText: preceding.isEmpty ? context.focusedFieldContent : preceding)
        let stripped = PolishPipeline.stripKeepTags(
            substituted, casual: casual)

        guard let polishChatClient else {
            return PolishPipeline.normalizeFormatting(stripped, casual: casual)
        }

        var prompt = PolishPipeline.systemPromptQwen
        if let tone = PolishPipeline.toneLabel(for: context.bundleID) {
            prompt += "\nStyle: \(tone)"
        }
        if !preceding.isEmpty {
            let suffix = preceding.count > 80
                ? String(preceding.suffix(80))
                : preceding
            prompt += "\nPreceding text: \(suffix)"
        } else if let content = context.focusedFieldContent, !content.isEmpty {
            let suffix = content.count > 80
                ? String(content.suffix(80))
                : content
            prompt += "\nPreceding text: \(PolishPipeline.sanitizeContextField(suffix))"
        }

        do {
            let polished = try await polishChatClient.complete(
                model: polishModel,
                systemPrompt: prompt,
                userPrompt: stripped)
            if polished.isEmpty {
                return PolishPipeline.normalizeFormatting(stripped, casual: casual)
            }
            if let fallback = PolishPipeline.guardAgainstTruncation(
                polished: polished, preprocessed: stripped) {
                return PolishPipeline.normalizeFormatting(fallback, casual: casual)
            }
            return PolishPipeline.normalizeFormatting(polished, casual: casual)
        } catch {
            Log.debug("[LocalStreaming] Polish failed: \(error)")
            return PolishPipeline.normalizeFormatting(stripped, casual: casual)
        }
    }

    // MARK: - Sentence Splitting

    /// Split text into sentences at sentence-ending punctuation.
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty {
            sentences.append(trailing)
        }
        return sentences
    }
}
