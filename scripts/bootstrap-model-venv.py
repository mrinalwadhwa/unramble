#!/usr/bin/env python3
"""Create and provision FreeFlow's repository-local model-tools venv."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Sequence


class BootstrapError(RuntimeError):
    """A safe, actionable model-tools environment failure."""


def remove_path(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return
    if stat.S_ISDIR(mode) and not stat.S_ISLNK(mode):
        shutil.rmtree(path)
    else:
        path.unlink()


def ensure_real_directory(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=True)
        mode = path.lstat().st_mode
    except OSError as error:
        raise BootstrapError(f"cannot prepare venv parent {path}: {error}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise BootstrapError(f"venv parent must be a real directory: {path}")


def open_lock(path: Path):
    flags = os.O_RDWR | os.O_CREAT
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise BootstrapError(f"cannot open venv bootstrap lock {path}: {error}") from error
    return os.fdopen(descriptor, "a+")


def create_venv(venv: Path) -> None:
    try:
        mode = venv.lstat().st_mode
    except FileNotFoundError:
        mode = None
    except OSError as error:
        raise BootstrapError(f"cannot inspect venv path {venv}: {error}") from error
    if mode is not None and (stat.S_ISLNK(mode) or not stat.S_ISDIR(mode)):
        remove_path(venv)

    ready = venv / ".ready"
    python = venv / "bin" / "python3"
    if ready.is_file() and python.is_file() and os.access(python, os.X_OK):
        return

    for stale in venv.parent.glob("venv-tmp-*"):
        remove_path(stale)
    staging = Path(tempfile.mkdtemp(prefix="venv-tmp-", dir=venv.parent))
    try:
        subprocess.run([sys.executable, "-m", "venv", str(staging)], check=True)
        (staging / ".ready").touch()
        remove_path(venv)
        os.replace(staging, venv)
    finally:
        remove_path(staging)


def canonical_package_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def locked_versions(requirements: bytes) -> dict[str, str]:
    try:
        text = requirements.decode("utf-8")
    except UnicodeDecodeError as error:
        raise BootstrapError("model-tool requirements are not valid UTF-8") from error

    versions: dict[str, str] = {}
    for raw_line in text.splitlines():
        if not raw_line or raw_line[0].isspace() or raw_line.startswith("#"):
            continue
        line = raw_line.rstrip(" \\")
        requirement, separator, marker = line.partition(";")
        if separator and "sys_platform == 'win32'" in marker:
            continue
        if "==" not in requirement:
            raise BootstrapError(
                f"model-tool requirement is not exactly pinned: {raw_line!r}"
            )
        name, version = requirement.split("==", 1)
        versions[canonical_package_name(name.strip())] = version.strip()
    if "huggingface-hub" not in versions:
        raise BootstrapError("model-tool requirements do not pin huggingface-hub")
    return versions


def environment_matches(venv: Path, expected: dict[str, str], version: str) -> bool:
    python = venv / "bin" / "python3"
    hf = venv / "bin" / "hf"
    if not hf.is_file() or not os.access(hf, os.X_OK):
        return False
    freeze = subprocess.run(
        [str(python), "-m", "pip", "freeze", "--all"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if freeze.returncode != 0:
        return False
    installed: dict[str, str] = {}
    for line in freeze.stdout.splitlines():
        if "==" not in line:
            continue
        name, installed_version = line.split("==", 1)
        installed[canonical_package_name(name)] = installed_version
    if any(installed.get(name) != locked for name, locked in expected.items()):
        return False
    return installed.get("huggingface-hub") == version


def install_huggingface(venv: Path, version: str, requirements: Path) -> None:
    try:
        mode = requirements.lstat().st_mode
        requirements_bytes = requirements.read_bytes()
    except OSError as error:
        raise BootstrapError(
            f"cannot read model-tool requirements {requirements}: {error}"
        ) from error
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise BootstrapError(
            f"model-tool requirements must be a real file: {requirements}"
        )

    lock_digest = hashlib.sha256(requirements_bytes).hexdigest()
    expected_versions = locked_versions(requirements_bytes)
    if expected_versions["huggingface-hub"] != version:
        raise BootstrapError(
            "--huggingface-version does not match the hash-locked requirements"
        )
    marker = venv / f".model-requirements-{lock_digest}"
    python = venv / "bin" / "python3"
    version_check = [
        str(python),
        "-c",
        "import huggingface_hub,sys; "
        "assert huggingface_hub.__version__ == sys.argv[1]",
        version,
    ]
    if marker.is_file() and environment_matches(
        venv, expected_versions, version
    ):
        return

    repair = marker.is_file()
    for stale_marker in (
        *venv.glob(".huggingface-hub-*"),
        *venv.glob(".model-requirements-*"),
    ):
        remove_path(stale_marker)
    install_command = [
        str(python),
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "--require-hashes",
        "--only-binary=:all:",
        "--no-deps",
        "--requirement",
        str(requirements),
    ]
    if repair:
        install_command.insert(4, "--force-reinstall")
    subprocess.run(install_command, check=True)
    subprocess.run([str(python), "-m", "pip", "check"], check=True)
    subprocess.run(version_check, check=True)
    if not environment_matches(venv, expected_versions, version):
        raise BootstrapError("installed model-tools environment does not match its lock")
    marker.touch()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--venv", required=True, type=Path)
    parser.add_argument("--requirements", type=Path)
    parser.add_argument("--huggingface-version")
    args = parser.parse_args(argv)
    if bool(args.requirements) != bool(args.huggingface_version):
        parser.error(
            "--requirements and --huggingface-version must be provided together"
        )

    venv = Path(os.path.abspath(args.venv))
    ensure_real_directory(venv.parent)
    lock_path = venv.parent / "venv-bootstrap.lock"
    with open_lock(lock_path) as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        create_venv(venv)
        if args.huggingface_version:
            assert args.requirements is not None
            requirements = Path(os.path.abspath(args.requirements))
            install_huggingface(venv, args.huggingface_version, requirements)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BootstrapError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
    except subprocess.CalledProcessError as error:
        command = " ".join(str(argument) for argument in error.cmd)
        print(
            f"ERROR: command failed with status {error.returncode}: {command}",
            file=sys.stderr,
        )
        raise SystemExit(1)
