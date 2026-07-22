# Training and test data for the polish model

Unramble cleans up dictated text with a small on-device model: Qwen3 0.6B plus a
LoRA fine-tuning adapter. This folder holds the data and settings that produce
that model, and the data that tests it.

## Polish model

The shipped adapter is committed under
`UnrambleApp/ModelSources/qwen3-0.6b-4bit-polish-adapter/`. It fine-tunes the
base Qwen3 0.6B model on the examples in this folder.

- `train.jsonl`, `valid.jsonl` — the fine-tuning examples. Each line is a
  `{"messages": [system, user, assistant]}` pair: raw dictation in, cleaned text
  out.
- `lora-config.yaml` — the fine-tuning settings.

Rebuild the adapter (requires the mlx-lm training stack):

    cd training
    python3 -m mlx_lm.lora --config lora-config.yaml

`train.jsonl` is the current version of this set. The exact copy used to
fine-tune the shipped adapter was overwritten during earlier iteration, so a
rebuild reproduces the same recipe and behavior rather than a byte-identical
adapter. The shipped adapter weights are committed, so this does not affect the
app.

## Test and evaluation data

- `polish-tests.yaml` — the single set of dictation-polish scenarios (raw input
  plus one or more acceptable outputs). It backs both the deterministic test
  suite and the model evaluation harness. Run `generate_test_data.py` to produce
  `polish-tests.json`, which the Swift tests load.
- `requirements.txt` — Python dependencies for training.
