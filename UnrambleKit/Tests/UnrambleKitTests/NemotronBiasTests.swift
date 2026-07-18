import Testing

@testable import UnrambleKit

@Suite("NemotronEngine – contextual biasing")
struct NemotronBiasTests {

    // Synthetic SentencePiece-style vocab (id → token). Word starts carry the
    // U+2581 marker; continuations do not.
    private let vocab = [
        "",       // 0  <unk>
        "\u{2581}P",  // 1  ▁P
        "ri",     // 2
        "y",      // 3
        "a",      // 4
        "o",      // 5
        "\u{2581}B",  // 6  ▁B
    ]

    @Test("Greedy tokenize resolves a phrase to subword ids")
    func tokenize() {
        // "Priya" → ▁P(1), ri(2), y(3), a(4) by greedy longest-match.
        #expect(BiasModel.tokenize("Priya", vocabulary: vocab) == [1, 2, 3, 4])
    }

    @Test("Untokenizable phrase yields no ids")
    func untokenizable() {
        // "Zeta" cannot be built from this vocab.
        #expect(BiasModel.tokenize("Zeta", vocabulary: vocab).isEmpty)
    }

    @Test("A phrase-initial token is never boosted from the start")
    func noForcedStart() {
        let model = BiasModel.build(
            phrases: ["Priya"], vocabulary: vocab, weight: 2)!
        let state = BiasState(model: model)
        // Nothing emitted yet: the recognizer must reach the name on its own.
        #expect(state.boosts().isEmpty)
    }

    @Test("Boosts follow an organically-started match to fix the tail")
    func continuationBoosts() {
        let model = BiasModel.build(
            phrases: ["Priya"], vocabulary: vocab, weight: 2)!
        var state = BiasState(model: model)
        state.advance(1)                       // ▁P emitted organically
        #expect(state.boosts() == [2: 2])      // expect "ri"
        state.advance(2)                       // ri
        #expect(state.boosts() == [3: 2])      // expect "y" (so "Prio" → "Priya")
    }

    @Test("A wrong first token never starts a match")
    func wrongStartNoMatch() {
        let model = BiasModel.build(
            phrases: ["Priya"], vocabulary: vocab, weight: 2)!
        var state = BiasState(model: model)
        state.advance(6)                       // ▁B (as in the "Bria" mishearing)
        #expect(state.boosts().isEmpty)
    }
}
