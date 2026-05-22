#!/usr/bin/env python3
"""Generate training data for fine-tuning Qwen3 on dictation polish.

Reads scenarios from polish-training-data.yaml and outputs JSONL with
{"messages": [system, user, assistant]} format compatible with
mlx-lm LoRA training.

Each scenario has an input (what the model receives after deterministic
preprocessing) and one or more accepted outputs. For training, the
first accepted output is used as the target.

Optional fields:
  style: "casual" — appends "Style: casual" to system prompt
  preceding_text: "..." — appends "Preceding text: ..." to system prompt

Usage:
    python3 generate_training_data.py
    python3 generate_training_data.py --split  # also generate train/valid split
"""

import json
import random
import sys
from pathlib import Path

import yaml

SYSTEM_PROMPT = (
    "Clean up this dictated text.\n"
    "Fix punctuation and capitalization.\n"
    "Return only the cleaned text."
)

TRAINING_YAML = Path(__file__).parent / "polish-training-data.yaml"
OUTPUT_PATH = Path(__file__).parent / "polish-training.jsonl"


def build_system_prompt(style: str | None = None,
                        preceding_text: str | None = None) -> str:
    prompt = SYSTEM_PROMPT
    if style:
        prompt += f"\nStyle: {style}"
    if preceding_text:
        prompt += f"\nPreceding text: {preceding_text}"
    return prompt


def build_example(input_text: str, output_text: str,
                  style: str | None = None,
                  preceding_text: str | None = None) -> dict:
    return {
        "messages": [
            {"role": "system",
             "content": build_system_prompt(style, preceding_text)},
            {"role": "user", "content": input_text},
            {"role": "assistant", "content": output_text.rstrip("\n")},
        ]
    }


def main():
    scenarios = yaml.safe_load(TRAINING_YAML.read_text())

    # --no-casual: exclude casual examples (for training normal-only adapter)
    exclude_casual = "--no-casual" in sys.argv

    examples = []
    for s in scenarios:
        if exclude_casual and s.get("style") == "casual":
            continue
        if s["accepted"]:
            examples.append(
                build_example(
                    s["input"], s["accepted"][0],
                    style=s.get("style"),
                    preceding_text=s.get("preceding_text")))

    random.seed(42)
    random.shuffle(examples)

    with open(OUTPUT_PATH, "w") as f:
        for ex in examples:
            f.write(json.dumps(ex, ensure_ascii=False) + "\n")

    print(f"Total examples: {len(examples)}")
    print(f"Written to: {OUTPUT_PATH}")

    # Also regenerate polish-tests.json for Swift consumption
    tests_yaml = Path(__file__).parent / "polish-tests.yaml"
    tests_json = Path(__file__).parent / "polish-tests.json"
    if tests_yaml.exists():
        test_scenarios = yaml.safe_load(tests_yaml.read_text())
        for s in test_scenarios:
            s["accepted"] = [a.rstrip("\n") for a in s["accepted"]]
        tests_json.write_text(
            json.dumps(test_scenarios, indent=2, ensure_ascii=False) + "\n")
        print(f"Regenerated polish-tests.json: {len(test_scenarios)} scenarios")

    # Also generate polish-training-eval.json for Swift consumption
    training_json = Path(__file__).parent / "polish-training-eval.json"
    eval_scenarios = []
    for s in scenarios:
        entry = {
            "category": s["category"],
            "input": s["input"],
            "accepted": [a.rstrip("\n") for a in s["accepted"]],
        }
        if s.get("style"):
            entry["style"] = s["style"]
        if s.get("preceding_text"):
            entry["preceding_text"] = s["preceding_text"]
        eval_scenarios.append(entry)
    training_json.write_text(
        json.dumps(eval_scenarios, indent=2, ensure_ascii=False) + "\n")
    print(f"Generated polish-training-eval.json: {len(eval_scenarios)} scenarios")

    if "--split" in sys.argv:
        split = int(len(examples) * 0.85)
        train, valid = examples[:split], examples[split:]
        train_path = Path(__file__).parent / "train.jsonl"
        valid_path = Path(__file__).parent / "valid.jsonl"
        with open(train_path, "w") as f:
            for ex in train:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")
        with open(valid_path, "w") as f:
            for ex in valid:
                f.write(json.dumps(ex, ensure_ascii=False) + "\n")
        print(f"Train: {len(train)}, Valid: {len(valid)}")


if __name__ == "__main__":
    main()
