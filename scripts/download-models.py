#!/usr/bin/env python3
"""Materialize the exact model pack declared by FreeFlowApp/models.json."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Mapping, Sequence


class MaterializationError(RuntimeError):
    """An actionable model-pack materialization failure."""


def run_verifier(
    verifier: Path,
    manifest: Path,
    models_dir: Path | None = None,
    *,
    quiet: bool = False,
) -> bool:
    command = [sys.executable, str(verifier), "--manifest", str(manifest)]
    if models_dir is None:
        command.append("--manifest-only")
    else:
        command.extend(("--models-dir", str(models_dir)))
    result = subprocess.run(
        command,
        check=False,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.DEVNULL if quiet else None,
    )
    return result.returncode == 0


def path_exists(path: Path) -> bool:
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    return True


def remove_path(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return
    if stat.S_ISDIR(mode) and not stat.S_ISLNK(mode):
        shutil.rmtree(path)
    else:
        path.unlink()


def ensure_real_directory(path: Path, label: str) -> None:
    try:
        path.mkdir(parents=True, exist_ok=True)
        mode = path.lstat().st_mode
    except OSError as error:
        raise MaterializationError(f"cannot prepare {label} {path}: {error}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise MaterializationError(f"{label} must be a real directory: {path}")


def open_lock(path: Path):
    flags = os.O_RDWR | os.O_CREAT
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise MaterializationError(
            f"cannot open model-pack lock {path}: {error}"
        ) from error
    return os.fdopen(descriptor, "a+")


def recover_interrupted_swap(
    work_dir: Path,
    models_dir: Path,
    verifier: Path,
    manifest: Path,
) -> None:
    for staging in work_dir.glob("staging-*"):
        remove_path(staging)

    backups = sorted(work_dir.glob("backup-*"))
    if not backups:
        return
    if len(backups) != 1:
        raise MaterializationError(
            f"multiple interrupted model-pack backups found in {work_dir}"
        )

    backup = backups[0]
    if not path_exists(models_dir):
        os.replace(backup, models_dir)
        return
    if run_verifier(verifier, manifest, models_dir, quiet=True):
        remove_path(backup)
        return

    remove_path(models_dir)
    os.replace(backup, models_dir)


def materialize_repository_model(
    root_dir: Path,
    destination: Path,
    source: Mapping[str, Any],
    files: Sequence[Mapping[str, Any]],
) -> None:
    revision = source["revision"]
    source_path = source["path"]
    print(f"Materializing repository model at {revision}", flush=True)
    subprocess.run(
        ["git", "-C", str(root_dir), "cat-file", "-e", f"{revision}^{{commit}}"],
        check=True,
    )
    for entry in files:
        relative_path = entry["path"]
        target = destination / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("wb") as output:
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(root_dir),
                    "show",
                    f"{revision}:{source_path}/{relative_path}",
                ],
                check=True,
                stdout=output,
            )


def materialize_huggingface_model(
    destination: Path,
    source: Mapping[str, Any],
    files: Sequence[Mapping[str, Any]],
    hf_command: str,
) -> None:
    repo = source["repo"]
    revision = source["revision"]
    print(f"Downloading {repo} at {revision}", flush=True)
    command = [
        hf_command,
        "download",
        repo,
        "--revision",
        revision,
        "--local-dir",
        str(destination),
    ]
    for entry in files:
        command.extend(("--include", entry["path"]))
    subprocess.run(command, check=True)
    remove_path(destination / ".cache")
    remove_path(destination / ".huggingface")


def require_unchanged_manifest(path: Path, expected: bytes) -> None:
    try:
        actual = path.read_bytes()
    except OSError as error:
        raise MaterializationError(f"cannot reread model manifest {path}: {error}") from error
    if actual != expected:
        raise MaterializationError("model manifest changed during materialization")


def materialize_pack(
    root_dir: Path,
    work_dir: Path,
    models_dir: Path,
    manifest: Path,
    source_manifest: Path,
    manifest_bytes: bytes,
    verifier: Path,
    raw_manifest: Mapping[str, Any],
    hf_command: str,
) -> None:
    staging = Path(tempfile.mkdtemp(prefix="staging-", dir=work_dir))
    backup = work_dir / f"backup-{uuid.uuid4().hex}"
    installed_new = False
    committed = False

    try:
        for model_id, model in raw_manifest["models"].items():
            destination = staging / model_id
            source = model["source"]
            if source["type"] == "repository":
                materialize_repository_model(
                    root_dir, destination, source, model["files"]
                )
            elif source["type"] == "huggingface":
                materialize_huggingface_model(
                    destination, source, model["files"], hf_command
                )
            else:
                raise MaterializationError(
                    f"unsupported source type for {model_id}: {source['type']}"
                )

        if not run_verifier(verifier, manifest, staging):
            raise MaterializationError("staged model pack failed verification")

        require_unchanged_manifest(source_manifest, manifest_bytes)
        if path_exists(models_dir):
            os.replace(models_dir, backup)
        installed_new = True
        os.replace(staging, models_dir)

        if not run_verifier(verifier, manifest, models_dir):
            raise MaterializationError("installed model pack failed verification")

        require_unchanged_manifest(source_manifest, manifest_bytes)
        committed = True
        remove_path(backup)
        print("All models ready.", flush=True)
    finally:
        if not committed:
            if installed_new:
                remove_path(models_dir)
            if path_exists(backup) and not path_exists(models_dir):
                os.replace(backup, models_dir)
        remove_path(staging)


def load_json(value: bytes, path: Path) -> Mapping[str, Any]:
    try:
        decoded = json.loads(value)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise MaterializationError(f"cannot read model manifest {path}: {error}") from error
    if not isinstance(decoded, dict):
        raise MaterializationError("model manifest root must be an object")
    return decoded


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--force", action="store_true", help="rematerialize a valid pack")
    mode.add_argument("--verify", action="store_true", help="verify without network access")
    mode.add_argument(
        "--run",
        nargs=argparse.REMAINDER,
        metavar="COMMAND",
        help="verify, then run a command while holding the model-pack lock",
    )
    args = parser.parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    root_dir = script_dir.parent
    app_dir = root_dir / "FreeFlowApp"
    work_dir = app_dir / ".model-work"
    models_dir = app_dir / "Resources" / "models"
    manifest = app_dir / "models.json"
    verifier = script_dir / "verify-model-pack.py"

    if not manifest.is_file():
        raise MaterializationError(f"model manifest not found: {manifest}")
    if not verifier.is_file():
        raise MaterializationError(f"model verifier not found: {verifier}")
    ensure_real_directory(work_dir, "model work directory")
    lock_path = work_dir / "materialize.lock"
    with open_lock(lock_path) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            manifest_bytes = manifest.read_bytes()
        except OSError as error:
            raise MaterializationError(
                f"cannot read model manifest {manifest}: {error}"
            ) from error
        snapshot = work_dir / f"manifest-{uuid.uuid4().hex}.json"
        snapshot.write_bytes(manifest_bytes)
        try:
            if not run_verifier(verifier, snapshot):
                return 1
            raw_manifest = load_json(manifest_bytes, manifest)
            recover_interrupted_swap(work_dir, models_dir, verifier, snapshot)

            if args.verify:
                return 0 if run_verifier(verifier, snapshot, models_dir) else 1
            if args.run is not None:
                if not args.run:
                    raise MaterializationError("--run requires a command")
                if not run_verifier(verifier, snapshot, models_dir):
                    return 1
                result = subprocess.run(args.run, check=False)
                require_unchanged_manifest(manifest, manifest_bytes)
                if not run_verifier(verifier, snapshot, models_dir):
                    return 1
                return result.returncode
            if not args.force and run_verifier(
                verifier, snapshot, models_dir, quiet=True
            ):
                print("Model pack is already complete and verified.", flush=True)
                return 0

            hf_command = shutil.which("hf")
            if hf_command is None:
                raise MaterializationError(
                    "hf CLI not found; run model materialization through Make"
                )
            materialize_pack(
                root_dir,
                work_dir,
                models_dir,
                snapshot,
                manifest,
                manifest_bytes,
                verifier,
                raw_manifest,
                hf_command,
            )
        finally:
            remove_path(snapshot)
    return 0


def interrupted(signum: int, _frame: object) -> None:
    raise InterruptedError(f"interrupted by signal {signum}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        raise SystemExit(main())
    except (MaterializationError, InterruptedError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("ERROR: interrupted", file=sys.stderr)
        raise SystemExit(130)
    except subprocess.CalledProcessError as error:
        command = " ".join(str(argument) for argument in error.cmd)
        print(
            f"ERROR: command failed with status {error.returncode}: {command}",
            file=sys.stderr,
        )
        raise SystemExit(1)
