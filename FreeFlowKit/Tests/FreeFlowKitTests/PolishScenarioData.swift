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
/// truth) and lives in training/. Found by walking up from the test
/// source file.
let allScenarios: [PolishScenario] = loadScenarios(from: "polish-tests.json")

/// All training scenarios loaded from polish-training-eval.json.
///
/// Used to evaluate the model against its own training data
/// through the full Swift pipeline (preprocessing → model → postprocessing).
let allTrainingScenarios: [PolishScenario] = loadScenarios(from: "polish-training-eval.json")

/// P1 eval scenarios — curated set of cases that must be 100% correct.
/// Covers: don't lose content, pass through clean input, handle ASR artifacts.
let allP1Scenarios: [PolishScenario] = loadScenarios(from: "p1-eval-set.json")

/// Load scenarios from a JSON file, applying environment-based filters.
///
/// - `FREEFLOW_TEST_CATEGORIES=list,meeting` — run only these categories
/// - `FREEFLOW_TEST_NO_CASUAL=1` — exclude casual scenarios
private func loadScenarios(from filename: String) -> [PolishScenario] {
    guard let url = findTrainingFile(filename) else {
        fatalError("\(filename) not found — walk up from \(#file)")
    }
    guard let data = try? Data(contentsOf: url),
          let entries = try? JSONDecoder().decode([ScenarioEntry].self, from: data)
    else {
        fatalError("Failed to parse \(filename)")
    }
    var scenarios = entries.map { scenarioFromEntry($0) }

    // Filter by category if specified (env var or flag file).
    if let cats = flagFileOrEnv(
        "FREEFLOW_TEST_CATEGORIES",
        flagPath: "/tmp/freeflow-test-categories"),
       !cats.isEmpty {
        let allowed = Set(cats.split(separator: ",").map(String.init))
        scenarios = scenarios.filter { allowed.contains($0.category) }
    }

    // Exclude casual if specified.
    if ProcessInfo.processInfo.environment["FREEFLOW_TEST_NO_CASUAL"] == "1" {
        scenarios = scenarios.filter { $0.style != "casual" }
    }

    return scenarios
}

/// Choose between test and training scenarios based on environment.
///
/// When `FREEFLOW_TEST_TRAINING=1` is set (env var or flag file),
/// return training scenarios. Otherwise return test scenarios. Applies
/// the same category and casual filters.
func evalScenarios() -> [PolishScenario] {
    // Load an arbitrary eval set (ScenarioEntry JSON) when pointed at a file.
    if let path = flagFileOrEnv(
        "FREEFLOW_EVAL_FILE", flagPath: "/tmp/freeflow-eval-file"),
        let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let entries = try? JSONDecoder().decode([ScenarioEntry].self, from: data)
    {
        return entries.map(scenarioFromEntry)
    }
    if ProcessInfo.processInfo.environment["FREEFLOW_TEST_P1"] == "1"
        || FileManager.default.fileExists(atPath: "/tmp/freeflow-test-p1") {
        return allP1Scenarios
    }
    if ProcessInfo.processInfo.environment["FREEFLOW_TEST_TRAINING"] == "1"
        || FileManager.default.fileExists(atPath: "/tmp/freeflow-test-training") {
        return allTrainingScenarios
    }
    return allScenarios
}

/// Read a flag file's contents as a comma-separated category filter,
/// or fall back to the environment variable.
private func flagFileOrEnv(_ envKey: String, flagPath: String) -> String? {
    if let content = try? String(contentsOfFile: flagPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !content.isEmpty {
        return content
    }
    return ProcessInfo.processInfo.environment[envKey]
}

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

private func findTrainingFile(_ name: String) -> URL? {
    var dir = URL(fileURLWithPath: #file)
    for _ in 0..<10 {
        dir = dir.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("training/\(name)")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}
