import Foundation

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Shared test data for all polish scenario tests. Scenarios are loaded from
// polish-tests.json (the single source of truth shared with the Python
// training data generator).
//
// Each scenario has a category, raw dictation input, and one or more
// acceptable polished outputs. Optional style and preceding_text fields
// control the system prompt sent to the model.
// ---------------------------------------------------------------------------

/// A single polish scenario with category, raw input, and acceptable outputs.
struct PolishScenario {
    let category: String
    let input: String
    let accepted: [String]
    let style: String?
    let precedingText: String?
    let context: AppContext

    init(category: String, input: String, accepted: [String],
         style: String? = nil, precedingText: String? = nil,
         context: AppContext = .empty) {
        self.category = category
        self.input = input
        self.accepted = accepted
        self.style = style
        self.precedingText = precedingText
        self.context = context
    }

    func matches(_ output: String) -> Bool {
        let normalize = { (s: String) in
            s.replacingOccurrences(of: "\u{2019}", with: "'")
             .replacingOccurrences(of: "\u{2018}", with: "'")
             .replacingOccurrences(of: "\u{201C}", with: "\"")
             .replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        let normalizedOutput = normalize(output)
        return accepted.contains { normalize($0) == normalizedOutput }
    }

    /// Build the system prompt for this scenario, including optional
    /// style and preceding text context.
    func systemPrompt() -> String {
        var prompt = PolishPipeline.systemPromptQwen
        if let style {
            prompt += "\nStyle: \(style)"
        }
        if let precedingText, !precedingText.isEmpty {
            prompt += "\nPreceding text: \(precedingText)"
        }
        return prompt
    }
}

/// All polish scenarios loaded from polish-tests.json.
///
/// The JSON file is generated from polish-tests.yaml (the source of
/// truth) and lives in .scratch/fine-tuning/. Found by walking up
/// from the test source file.
let allScenarios: [PolishScenario] = {
    guard let url = findScenariosJSON() else {
        fatalError("polish-tests.json not found — walk up from \(#file)")
    }
    guard let data = try? Data(contentsOf: url),
          let entries = try? JSONDecoder().decode([ScenarioEntry].self, from: data)
    else {
        fatalError("Failed to parse polish-tests.json")
    }
    return entries.map { scenarioFromEntry($0) }
}()

/// All training scenarios loaded from polish-training-eval.json.
///
/// Used to evaluate the model against its own training data
/// through the full Swift pipeline (preprocessing → model → postprocessing).
let allTrainingScenarios: [PolishScenario] = {
    guard let url = findFineTuningFile("polish-training-eval.json") else {
        fatalError("polish-training-eval.json not found — walk up from \(#file)")
    }
    guard let data = try? Data(contentsOf: url),
          let entries = try? JSONDecoder().decode([ScenarioEntry].self, from: data)
    else {
        fatalError("Failed to parse polish-training-eval.json")
    }
    return entries.map { scenarioFromEntry($0) }
}()

/// Build a PolishScenario from a JSON entry, constructing an AppContext
/// that reflects the scenario's style and preceding text so that
/// `buildCloudSystemPrompt` and `toneLabel` work correctly.
private func scenarioFromEntry(_ entry: ScenarioEntry) -> PolishScenario {
    let bundleID = entry.style == "casual"
        ? "com.tinyspeck.slackmacgap" : ""
    let context = AppContext(
        bundleID: bundleID,
        appName: "",
        windowTitle: "",
        focusedFieldContent: entry.preceding_text)
    return PolishScenario(
        category: entry.category, input: entry.input,
        accepted: entry.accepted,
        style: entry.style, precedingText: entry.preceding_text,
        context: context)
}

// MARK: - JSON loading

private struct ScenarioEntry: Decodable {
    let category: String
    let input: String
    let accepted: [String]
    let style: String?
    let preceding_text: String?
}

private func findFineTuningFile(_ name: String) -> URL? {
    var dir = URL(fileURLWithPath: #file)
    for _ in 0..<10 {
        dir = dir.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent(
            ".scratch/fine-tuning/\(name)")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func findScenariosJSON() -> URL? {
    findFineTuningFile("polish-tests.json")
}
