/// Polish prompt for Qwen3 0.6B running via MLX on-device.
///
/// Qwen3 0.6B is a 0.6-billion parameter model running 4-bit quantized
/// on Apple Silicon GPUs via mlx-swift. It uses `/no_think` to suppress
/// chain-of-thought reasoning. This prompt is tuned separately from the
/// Apple Foundation Models prompt. Edit it to tune Qwen3 polish behavior.
extension PolishPipeline {
    public static let systemPromptQwen = """
Clean up this dictated text.
Fix punctuation and capitalization.
Return only the cleaned text.
"""
}
