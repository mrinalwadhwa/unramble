#!/usr/bin/env python3
"""Validate the reproducible three-artifact FreeFlow model pack."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
MODEL_ROLES = {
    "nemotron-speech-streaming-en-0.6b-coreml": "speech-to-text",
    "qwen3-0.6b-4bit": "language-model",
    "qwen3-0.6b-4bit-polish-adapter": "polish-adapter",
}
ADAPTER_ID = "qwen3-0.6b-4bit-polish-adapter"
QWEN_ID = "qwen3-0.6b-4bit"
ADAPTER_REPOSITORY_PATH = f"FreeFlowApp/Resources/models/{ADAPTER_ID}"
HEX_40 = re.compile(r"[0-9a-f]{40}\Z")
HEX_64 = re.compile(r"[0-9a-f]{64}\Z")
HF_REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\Z")


class ValidationError(ValueError):
    """A model pack validation error suitable for command-line output."""


@dataclass(frozen=True)
class FileRecord:
    path: str
    size: int
    sha256: str


@dataclass(frozen=True)
class Requirement:
    model: str
    tree_sha256: str


@dataclass(frozen=True)
class ModelRecord:
    model_id: str
    role: str
    files: tuple[FileRecord, ...]
    tree_sha256: str
    requirement: Requirement | None


@dataclass(frozen=True)
class Manifest:
    models: Mapping[str, ModelRecord]


def _object(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ValidationError(f"{context} must be an object")
    return value


def _exact_fields(value: Mapping[str, Any], expected: set[str], context: str) -> None:
    missing = sorted(expected - value.keys())
    unknown = sorted(value.keys() - expected)
    details = []
    if missing:
        details.append(f"missing fields: {', '.join(missing)}")
    if unknown:
        details.append(f"unknown fields: {', '.join(unknown)}")
    if details:
        raise ValidationError(f"{context} has {'; '.join(details)}")


def _lower_hex(value: Any, length: int, context: str) -> str:
    pattern = HEX_40 if length == 40 else HEX_64
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ValidationError(
            f"{context} must be exactly {length} lowercase hexadecimal characters"
        )
    return value


def _relative_path(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValidationError(f"{context} must be a non-empty relative path")
    if "\\" in value:
        raise ValidationError(f"{context} contains an unsafe path separator")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValidationError(f"{context} contains an ASCII control character")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise ValidationError(f"{context} is not valid UTF-8") from error

    path = PurePosixPath(value)
    if path.is_absolute() or value.startswith("/"):
        raise ValidationError(f"{context} must be relative, not absolute: {value!r}")
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise ValidationError(f"{context} contains an unsafe path component: {value!r}")
    if path.as_posix() != value:
        raise ValidationError(f"{context} is not canonical: {value!r}")
    return value


def _source(
    value: Any,
    context: str,
    expected_type: str,
    expected_repository_path: str | None = None,
) -> None:
    source = _object(value, context)
    if "type" not in source:
        raise ValidationError(f"{context} has missing fields: type")
    source_type = source.get("type")
    if source_type != expected_type:
        raise ValidationError(f"{context}.type must be {expected_type!r}")
    if source_type == "huggingface":
        _exact_fields(source, {"type", "repo", "revision"}, context)
        repo = source["repo"]
        if not isinstance(repo, str) or HF_REPO.fullmatch(repo) is None:
            raise ValidationError(
                f"{context}.repo must be a Hugging Face owner/repository name"
            )
    elif source_type == "repository":
        _exact_fields(source, {"type", "path", "revision"}, context)
        repository_path = _relative_path(source["path"], f"{context}.path")
        if (
            expected_repository_path is not None
            and repository_path != expected_repository_path
        ):
            raise ValidationError(
                f"{context}.path must be {expected_repository_path!r}"
            )
    else:
        raise ValidationError(f"{context}.type must be 'huggingface' or 'repository'")
    _lower_hex(source["revision"], 40, f"{context}.revision")


def canonical_tree_sha256(files: Iterable[FileRecord]) -> str:
    digest = hashlib.sha256()
    for record in sorted(files, key=lambda item: item.path):
        digest.update(record.path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(record.size).encode("ascii"))
        digest.update(b"\0")
        digest.update(record.sha256.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _files(value: Any, context: str) -> tuple[FileRecord, ...]:
    if not isinstance(value, list) or not value:
        raise ValidationError(f"{context} must be a non-empty array")

    records = []
    paths: set[str] = set()
    portable_paths: dict[str, str] = {}
    for index, raw_record in enumerate(value):
        record_context = f"{context}[{index}]"
        item = _object(raw_record, record_context)
        _exact_fields(item, {"path", "size", "sha256"}, record_context)
        path = _relative_path(item["path"], f"{record_context}.path")
        if path in paths:
            raise ValidationError(f"{context} contains duplicate path: {path!r}")
        paths.add(path)

        portable_path = unicodedata.normalize("NFC", path).casefold()
        previous = portable_paths.get(portable_path)
        if previous is not None:
            raise ValidationError(
                f"{context} contains paths that collide on supported filesystems: "
                f"{previous!r} and {path!r}"
            )
        portable_paths[portable_path] = path

        size = item["size"]
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ValidationError(f"{record_context}.size must be a non-negative integer")
        sha256 = _lower_hex(item["sha256"], 64, f"{record_context}.sha256")
        records.append(FileRecord(path=path, size=size, sha256=sha256))
    return tuple(records)


def _reject_duplicate_json_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"manifest JSON contains duplicate key: {key!r}")
        result[key] = value
    return result


def load_manifest(path: Path) -> Manifest:
    try:
        with path.open("r", encoding="utf-8") as handle:
            raw = json.load(handle, object_pairs_hook=_reject_duplicate_json_keys)
    except ValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValidationError(f"cannot read manifest {path}: {error}") from error

    root = _object(raw, "manifest")
    _exact_fields(root, {"schemaVersion", "models"}, "manifest")
    if (
        isinstance(root["schemaVersion"], bool)
        or not isinstance(root["schemaVersion"], int)
        or root["schemaVersion"] != SCHEMA_VERSION
    ):
        raise ValidationError(f"manifest.schemaVersion must be {SCHEMA_VERSION}")

    models = _object(root["models"], "manifest.models")
    expected_ids = set(MODEL_ROLES)
    actual_ids = set(models)
    if actual_ids != expected_ids:
        details = []
        missing = sorted(expected_ids - actual_ids)
        unknown = sorted(actual_ids - expected_ids)
        if missing:
            details.append(f"missing model IDs: {', '.join(missing)}")
        if unknown:
            details.append(f"unknown model IDs: {', '.join(unknown)}")
        raise ValidationError(f"manifest.models has {'; '.join(details)}")

    parsed: dict[str, ModelRecord] = {}
    for model_id, expected_role in MODEL_ROLES.items():
        context = f"manifest.models[{model_id!r}]"
        model = _object(models[model_id], context)
        expected_fields = {"role", "source", "files", "treeSha256"}
        if model_id == ADAPTER_ID:
            expected_fields.add("requires")
        _exact_fields(model, expected_fields, context)

        if model["role"] != expected_role:
            raise ValidationError(f"{context}.role must be {expected_role!r}")
        expected_source_type = "repository" if model_id == ADAPTER_ID else "huggingface"
        _source(
            model["source"],
            f"{context}.source",
            expected_type=expected_source_type,
            expected_repository_path=(
                ADAPTER_REPOSITORY_PATH if model_id == ADAPTER_ID else None
            ),
        )
        files = _files(model["files"], f"{context}.files")
        tree_sha256 = _lower_hex(model["treeSha256"], 64, f"{context}.treeSha256")
        canonical_sha256 = canonical_tree_sha256(files)
        if tree_sha256 != canonical_sha256:
            raise ValidationError(
                f"{context}.treeSha256 mismatch: declared {tree_sha256}, "
                f"canonical digest is {canonical_sha256}"
            )

        requirement = None
        if model_id == ADAPTER_ID:
            requires_context = f"{context}.requires"
            requires = _object(model["requires"], requires_context)
            _exact_fields(requires, {"model", "treeSha256"}, requires_context)
            if requires["model"] != QWEN_ID:
                raise ValidationError(f"{requires_context}.model must be {QWEN_ID!r}")
            requirement = Requirement(
                model=requires["model"],
                tree_sha256=_lower_hex(
                    requires["treeSha256"], 64, f"{requires_context}.treeSha256"
                ),
            )

        parsed[model_id] = ModelRecord(
            model_id=model_id,
            role=expected_role,
            files=files,
            tree_sha256=tree_sha256,
            requirement=requirement,
        )

    adapter_requirement = parsed[ADAPTER_ID].requirement
    assert adapter_requirement is not None
    if adapter_requirement.tree_sha256 != parsed[QWEN_ID].tree_sha256:
        raise ValidationError(
            f"manifest.models[{ADAPTER_ID!r}].requires.treeSha256 does not match "
            f"the declared {QWEN_ID!r} treeSha256"
        )
    return Manifest(models=parsed)


def _scan_model_directory(root: Path, model_id: str) -> tuple[set[str], set[str]]:
    files: set[str] = set()
    directories: set[str] = set()

    def walk_error(error: OSError) -> None:
        raise ValidationError(f"model {model_id!r}: cannot traverse directory: {error}")

    for current_root, dir_names, file_names in os.walk(
        root, topdown=True, onerror=walk_error, followlinks=False
    ):
        current = Path(current_root)
        for name in dir_names:
            path = current / name
            relative = path.relative_to(root).as_posix()
            try:
                mode = path.lstat().st_mode
            except OSError as error:
                raise ValidationError(
                    f"model {model_id!r}: cannot inspect {relative!r}: {error}"
                ) from error
            if stat.S_ISLNK(mode):
                raise ValidationError(
                    f"model {model_id!r}: symlink is not allowed: {relative!r}"
                )
            if not stat.S_ISDIR(mode):
                raise ValidationError(
                    f"model {model_id!r}: non-directory entry: {relative!r}"
                )
            directories.add(relative)
        for name in file_names:
            path = current / name
            relative = path.relative_to(root).as_posix()
            try:
                mode = path.lstat().st_mode
            except OSError as error:
                raise ValidationError(
                    f"model {model_id!r}: cannot inspect {relative!r}: {error}"
                ) from error
            if stat.S_ISLNK(mode):
                raise ValidationError(
                    f"model {model_id!r}: symlink is not allowed: {relative!r}"
                )
            if not stat.S_ISREG(mode):
                raise ValidationError(
                    f"model {model_id!r}: non-regular file is not allowed: {relative!r}"
                )
            files.add(relative)
    return files, directories


def _sha256_file(
    path: Path, model_id: str, relative_path: str, expected_size: int
) -> str:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as handle:
            before = os.fstat(handle.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise ValidationError(
                    f"model {model_id!r}: non-regular file is not allowed: {relative_path!r}"
                )
            if before.st_size != expected_size:
                raise ValidationError(
                    f"model {model_id!r}: size mismatch for {relative_path!r}: "
                    f"expected {expected_size}, found {before.st_size}"
                )
            digest = hashlib.sha256()
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            after = os.fstat(handle.fileno())
    except ValidationError:
        raise
    except OSError as error:
        raise ValidationError(
            f"model {model_id!r}: cannot hash {relative_path!r}: {error}"
        ) from error

    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise ValidationError(
            f"model {model_id!r}: file changed while hashing: {relative_path!r}"
        )
    return digest.hexdigest()


def validate_models_directory(manifest: Manifest, models_dir: Path) -> tuple[int, int]:
    try:
        root_mode = models_dir.lstat().st_mode
    except OSError as error:
        raise ValidationError(f"cannot inspect models directory {models_dir}: {error}") from error
    if stat.S_ISLNK(root_mode) or not stat.S_ISDIR(root_mode):
        raise ValidationError(f"models directory must be a real directory, not a symlink: {models_dir}")

    try:
        with os.scandir(models_dir) as entries:
            root_entries = {entry.name for entry in entries}
    except OSError as error:
        raise ValidationError(f"cannot list models directory {models_dir}: {error}") from error
    expected_ids = set(MODEL_ROLES)
    actual_ids = root_entries
    if actual_ids != expected_ids:
        details = []
        missing = sorted(expected_ids - actual_ids)
        unexpected = sorted(actual_ids - expected_ids)
        if missing:
            details.append(f"missing model directories: {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected top-level entries: {', '.join(unexpected)}")
        raise ValidationError(f"models directory has {'; '.join(details)}")

    total_files = 0
    total_bytes = 0
    for model_id, model in manifest.models.items():
        model_root = models_dir / model_id
        try:
            mode = model_root.lstat().st_mode
        except OSError as error:
            raise ValidationError(f"model {model_id!r}: cannot inspect directory: {error}") from error
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise ValidationError(f"model {model_id!r}: model root must be a real directory")

        actual_files, actual_directories = _scan_model_directory(model_root, model_id)
        expected_files = {record.path for record in model.files}
        expected_directories = {
            parent.as_posix()
            for record in model.files
            for parent in PurePosixPath(record.path).parents
            if parent.as_posix() != "."
        }
        missing = sorted(expected_files - actual_files)
        unexpected = sorted(actual_files - expected_files)
        unexpected_directories = sorted(actual_directories - expected_directories)
        if missing or unexpected or unexpected_directories:
            details = []
            if missing:
                details.append(f"missing files: {', '.join(repr(path) for path in missing)}")
            if unexpected:
                details.append(f"unexpected files: {', '.join(repr(path) for path in unexpected)}")
            if unexpected_directories:
                details.append(
                    "unexpected directories: "
                    + ", ".join(repr(path) for path in unexpected_directories)
                )
            raise ValidationError(f"model {model_id!r}: {'; '.join(details)}")

        model_bytes = 0
        for record in model.files:
            actual_sha256 = _sha256_file(
                model_root / Path(*PurePosixPath(record.path).parts),
                model_id,
                record.path,
                record.size,
            )
            if actual_sha256 != record.sha256:
                raise ValidationError(
                    f"model {model_id!r}: SHA-256 mismatch for {record.path!r}: "
                    f"expected {record.sha256}, found {actual_sha256}"
                )
            model_bytes += record.size

        print(f"OK {model_id}: {len(model.files)} files, {model_bytes} bytes")
        total_files += len(model.files)
        total_bytes += model_bytes
    return total_files, total_bytes


def _print_manifest_success(manifest: Manifest) -> tuple[int, int]:
    total_files = 0
    total_bytes = 0
    for model_id, model in manifest.models.items():
        model_bytes = sum(record.size for record in model.files)
        print(f"OK {model_id}: manifest declares {len(model.files)} files, {model_bytes} bytes")
        total_files += len(model.files)
        total_bytes += model_bytes
    return total_files, total_bytes


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path, help="model pack manifest JSON")
    parser.add_argument("--models-dir", type=Path, help="directory containing the three models")
    parser.add_argument(
        "--manifest-only",
        action="store_true",
        help="validate only manifest schema and cross-artifact constraints",
    )
    args = parser.parse_args(argv)
    if not args.manifest_only and args.models_dir is None:
        parser.error("--models-dir is required unless --manifest-only is used")

    try:
        manifest = load_manifest(args.manifest)
        if args.manifest_only:
            total_files, total_bytes = _print_manifest_success(manifest)
            print(
                f"Manifest valid: {len(manifest.models)} models, "
                f"{total_files} files, {total_bytes} bytes"
            )
        else:
            assert args.models_dir is not None
            total_files, total_bytes = validate_models_directory(manifest, args.models_dir)
            print(
                f"Verified {len(manifest.models)} models, "
                f"{total_files} files, {total_bytes} bytes"
            )
    except ValidationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
