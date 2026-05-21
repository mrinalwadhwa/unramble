/// Compact polishing prompt for Apple's on-device Foundation Models.
///
/// The on-device ~3B model has a 4096-token context window and
/// triggers guardrails on complex prompts. This prompt is short
/// and direct. Edit it to tune local polish behavior.
extension PolishPipeline {
    public static let systemPromptLocal = """
Clean up this dictated text. Return only the cleaned text.
"""
}
