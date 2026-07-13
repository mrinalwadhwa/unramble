#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify-model-pack.py"
MODEL_ROLES = {
    "nemotron-speech-streaming-en-0.6b-coreml": "speech-to-text",
    "qwen3-0.6b-4bit": "language-model",
    "qwen3-0.6b-4bit-polish-adapter": "polish-adapter",
}
NEMOTRON_ID, QWEN_ID, ADAPTER_ID = MODEL_ROLES


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def tree_sha256(files: list[dict[str, object]]) -> str:
    digest = hashlib.sha256()
    for record in sorted(files, key=lambda item: str(item["path"])):
        digest.update(str(record["path"]).encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(record["size"]).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(record["sha256"]).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


class VerifyModelPackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.models_dir = self.root / "models"
        self.manifest_path = self.root / "models.json"
        self.contents = {
            NEMOTRON_ID: {"nemotron_coreml_560ms/tokenizer.json": b"nemotron-tokenizer"},
            QWEN_ID: {"model.safetensors": b"qwen-weights"},
            ADAPTER_ID: {"adapters.safetensors": b"adapter-weights"},
        }
        self.manifest = self.make_manifest()
        self.write_pack()
        self.write_manifest()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def make_manifest(self) -> dict[str, object]:
        models: dict[str, object] = {}
        for index, (model_id, role) in enumerate(MODEL_ROLES.items(), start=1):
            files = [
                {"path": path, "size": len(content), "sha256": sha256(content)}
                for path, content in self.contents[model_id].items()
            ]
            if model_id == ADAPTER_ID:
                source = {
                    "type": "repository",
                    "path": f"FreeFlowApp/Resources/models/{ADAPTER_ID}",
                    "revision": f"{index:x}" * 40,
                }
            else:
                source = {
                    "type": "huggingface",
                    "repo": f"freeflow/{model_id}",
                    "revision": f"{index:x}" * 40,
                }
            models[model_id] = {
                "role": role,
                "source": source,
                "files": files,
                "treeSha256": tree_sha256(files),
            }
        adapter = models[ADAPTER_ID]
        assert isinstance(adapter, dict)
        qwen = models[QWEN_ID]
        assert isinstance(qwen, dict)
        adapter["requires"] = {"model": QWEN_ID, "treeSha256": qwen["treeSha256"]}
        return {"schemaVersion": 1, "models": models}

    def write_pack(self) -> None:
        for model_id, files in self.contents.items():
            for relative_path, content in files.items():
                path = self.models_dir / model_id / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)

    def write_manifest(self) -> None:
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def run_verifier(self, *extra_arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--manifest",
                str(self.manifest_path),
                *extra_arguments,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def model(self, model_id: str) -> dict[str, object]:
        models = self.manifest["models"]
        assert isinstance(models, dict)
        model = models[model_id]
        assert isinstance(model, dict)
        return model

    def test_valid_three_model_pack(self) -> None:
        result = self.run_verifier("--models-dir", str(self.models_dir))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"OK {NEMOTRON_ID}: 1 files", result.stdout)
        self.assertIn("Verified 3 models, 3 files", result.stdout)

    def test_manifest_only_does_not_require_models_directory(self) -> None:
        shutil.rmtree(self.models_dir)

        result = self.run_verifier("--manifest-only")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Manifest valid: 3 models, 3 files", result.stdout)

    def test_requires_models_directory_without_manifest_only(self) -> None:
        result = self.run_verifier()

        self.assertEqual(result.returncode, 2)
        self.assertIn("--models-dir is required", result.stderr)

    def test_rejects_missing_and_unknown_model_ids(self) -> None:
        models = self.manifest["models"]
        assert isinstance(models, dict)
        models["unknown-model"] = models.pop(NEMOTRON_ID)
        self.write_manifest()

        result = self.run_verifier("--manifest-only")

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"missing model IDs: {NEMOTRON_ID}", result.stderr)
        self.assertIn("unknown model IDs: unknown-model", result.stderr)

    def test_rejects_unknown_and_missing_fields(self) -> None:
        qwen = self.model(QWEN_ID)
        qwen["extra"] = True
        del qwen["role"]
        self.write_manifest()

        result = self.run_verifier("--manifest-only")

        self.assertEqual(result.returncode, 1)
        self.assertIn("missing fields: role", result.stderr)
        self.assertIn("unknown fields: extra", result.stderr)

    def test_rejects_duplicate_and_unsafe_file_paths(self) -> None:
        cases = (
            ("model.safetensors", "duplicate path"),
            ("../model.safetensors", "unsafe path component"),
            ("/model.safetensors", "must be relative, not absolute"),
        )
        for path, expected_error in cases:
            with self.subTest(path=path):
                self.manifest = self.make_manifest()
                qwen = self.model(QWEN_ID)
                files = qwen["files"]
                assert isinstance(files, list)
                duplicate = dict(files[0])
                duplicate["path"] = path
                files.append(duplicate)
                qwen["treeSha256"] = tree_sha256(files)
                adapter = self.model(ADAPTER_ID)
                requires = adapter["requires"]
                assert isinstance(requires, dict)
                requires["treeSha256"] = qwen["treeSha256"]
                self.write_manifest()

                result = self.run_verifier("--manifest-only")

                self.assertEqual(result.returncode, 1)
                self.assertIn(expected_error, result.stderr)

    def test_rejects_malformed_revision_and_hash(self) -> None:
        qwen = self.model(QWEN_ID)
        source = qwen["source"]
        assert isinstance(source, dict)
        source["revision"] = "main"
        files = qwen["files"]
        assert isinstance(files, list)
        files[0]["sha256"] = "ABC"
        self.write_manifest()

        result = self.run_verifier("--manifest-only")

        self.assertEqual(result.returncode, 1)
        self.assertIn("revision must be exactly 40 lowercase hexadecimal", result.stderr)

        source["revision"] = "2" * 40
        self.write_manifest()
        result = self.run_verifier("--manifest-only")
        self.assertEqual(result.returncode, 1)
        self.assertIn("sha256 must be exactly 64 lowercase hexadecimal", result.stderr)

    def test_rejects_wrong_source_types(self) -> None:
        cases = (
            (
                QWEN_ID,
                {
                    "type": "repository",
                    "path": f"FreeFlowApp/Resources/models/{QWEN_ID}",
                    "revision": "2" * 40,
                },
                "source.type must be 'huggingface'",
            ),
            (
                ADAPTER_ID,
                {
                    "type": "huggingface",
                    "repo": "freeflow/adapter",
                    "revision": "3" * 40,
                },
                "source.type must be 'repository'",
            ),
        )
        for model_id, source, expected_error in cases:
            with self.subTest(model_id=model_id):
                self.manifest = self.make_manifest()
                self.model(model_id)["source"] = source
                self.write_manifest()

                result = self.run_verifier("--manifest-only")

                self.assertEqual(result.returncode, 1)
                self.assertIn(expected_error, result.stderr)

    def test_rejects_wrong_adapter_repository_path(self) -> None:
        adapter = self.model(ADAPTER_ID)
        source = adapter["source"]
        assert isinstance(source, dict)
        source["path"] = "FreeFlowApp/Resources/models/wrong-adapter"
        self.write_manifest()

        result = self.run_verifier("--manifest-only")

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            f"source.path must be 'FreeFlowApp/Resources/models/{ADAPTER_ID}'",
            result.stderr,
        )

    def test_rejects_ascii_control_characters_in_paths(self) -> None:
        cases = ("file", "repository")
        for path_kind in cases:
            with self.subTest(path_kind=path_kind):
                self.manifest = self.make_manifest()
                if path_kind == "file":
                    nemotron = self.model(NEMOTRON_ID)
                    files = nemotron["files"]
                    assert isinstance(files, list)
                    files[0]["path"] = "nemotron_coreml_560ms/tokenizer\n.json"
                    nemotron["treeSha256"] = tree_sha256(files)
                else:
                    adapter = self.model(ADAPTER_ID)
                    source = adapter["source"]
                    assert isinstance(source, dict)
                    source["path"] = (
                        f"FreeFlowApp/Resources/models/{ADAPTER_ID}\t"
                    )
                self.write_manifest()

                result = self.run_verifier("--manifest-only")

                self.assertEqual(result.returncode, 1)
                self.assertIn("contains an ASCII control character", result.stderr)

    def test_rejects_wrong_tree_digest(self) -> None:
        self.model(NEMOTRON_ID)["treeSha256"] = "0" * 64
        self.write_manifest()

        result = self.run_verifier("--manifest-only")

        self.assertEqual(result.returncode, 1)
        self.assertIn("canonical digest is", result.stderr)

    def test_rejects_adapter_requirement_for_wrong_base_or_digest(self) -> None:
        adapter = self.model(ADAPTER_ID)
        requires = adapter["requires"]
        assert isinstance(requires, dict)
        requires["model"] = NEMOTRON_ID
        self.write_manifest()

        result = self.run_verifier("--manifest-only")

        self.assertEqual(result.returncode, 1)
        self.assertIn(f"requires.model must be '{QWEN_ID}'", result.stderr)

        requires["model"] = QWEN_ID
        requires["treeSha256"] = "0" * 64
        self.write_manifest()
        result = self.run_verifier("--manifest-only")
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match", result.stderr)

    def test_rejects_requires_on_non_adapter_model(self) -> None:
        self.model(QWEN_ID)["requires"] = {
            "model": QWEN_ID,
            "treeSha256": self.model(QWEN_ID)["treeSha256"],
        }
        self.write_manifest()

        result = self.run_verifier("--manifest-only")

        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown fields: requires", result.stderr)

    def test_rejects_missing_and_unexpected_files(self) -> None:
        missing_path = self.models_dir / QWEN_ID / "model.safetensors"
        missing_path.unlink()
        unexpected_path = self.models_dir / QWEN_ID / "unexpected.bin"
        unexpected_path.write_bytes(b"extra")

        result = self.run_verifier("--models-dir", str(self.models_dir))

        self.assertEqual(result.returncode, 1)
        self.assertIn("missing files: 'model.safetensors'", result.stderr)
        self.assertIn("unexpected files: 'unexpected.bin'", result.stderr)

    def test_rejects_wrong_size_before_hash(self) -> None:
        path = self.models_dir / QWEN_ID / "model.safetensors"
        path.write_bytes(b"different-size")

        result = self.run_verifier("--models-dir", str(self.models_dir))

        self.assertEqual(result.returncode, 1)
        self.assertIn("size mismatch", result.stderr)

    def test_rejects_same_size_content_hash_mismatch(self) -> None:
        path = self.models_dir / QWEN_ID / "model.safetensors"
        path.write_bytes(b"x" * len(b"qwen-weights"))

        result = self.run_verifier("--models-dir", str(self.models_dir))

        self.assertEqual(result.returncode, 1)
        self.assertIn("SHA-256 mismatch", result.stderr)

    def test_rejects_symlinks(self) -> None:
        path = self.models_dir / QWEN_ID / "model.safetensors"
        path.unlink()
        path.symlink_to(self.root / "outside")

        result = self.run_verifier("--models-dir", str(self.models_dir))

        self.assertEqual(result.returncode, 1)
        self.assertIn("symlink is not allowed", result.stderr)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO files are not supported")
    def test_rejects_non_regular_files(self) -> None:
        path = self.models_dir / QWEN_ID / "model.safetensors"
        path.unlink()
        os.mkfifo(path)

        result = self.run_verifier("--models-dir", str(self.models_dir))

        self.assertEqual(result.returncode, 1)
        self.assertIn("non-regular file is not allowed", result.stderr)

    def test_rejects_extra_top_level_entry(self) -> None:
        (self.models_dir / "stale-model").mkdir()

        result = self.run_verifier("--models-dir", str(self.models_dir))

        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected top-level entries: stale-model", result.stderr)


if __name__ == "__main__":
    unittest.main()
