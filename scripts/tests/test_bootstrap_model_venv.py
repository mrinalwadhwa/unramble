#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "bootstrap-model-venv.py"


class BootstrapModelVenvIntegrationTests(unittest.TestCase):
    def test_concurrent_create_only_invocations_produce_one_ready_venv(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            venv = root / "model-tools"
            environment = os.environ.copy()
            environment.update(
                {
                    "PIP_DISABLE_PIP_VERSION_CHECK": "1",
                    "PIP_NO_INDEX": "1",
                    "PYTHONNOUSERSITE": "1",
                }
            )
            command = [sys.executable, str(SCRIPT), "--venv", str(venv)]
            processes: list[subprocess.Popen[str]] = []
            outputs: list[tuple[str, str]] = []
            try:
                for _ in range(2):
                    processes.append(
                        subprocess.Popen(
                            command,
                            env=environment,
                            text=True,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                        )
                    )
                for process in processes:
                    outputs.append(process.communicate(timeout=30))
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                for process in processes:
                    if process.poll() is None:
                        try:
                            process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()

            for process, (stdout, stderr) in zip(processes, outputs):
                self.assertEqual(
                    process.returncode,
                    0,
                    f"bootstrap failed\nstdout:\n{stdout}\nstderr:\n{stderr}",
                )

            ready_markers = list(root.rglob(".ready"))
            self.assertEqual(ready_markers, [venv / ".ready"])
            python = venv / "bin" / "python3"
            self.assertTrue(python.is_file())
            probe = subprocess.run(
                [
                    str(python),
                    "-c",
                    "import pathlib,sys; print(pathlib.Path(sys.prefix).resolve())",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(probe.returncode, 0, probe.stderr)
            self.assertEqual(Path(probe.stdout.strip()), venv.resolve())
            self.assertEqual(list(root.glob("venv-tmp-*")), [])
            self.assertEqual(list(venv.glob(".huggingface-hub-*")), [])

    def test_stale_huggingface_marker_does_not_skip_package_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            venv = root / "model-tools"
            environment = os.environ.copy()
            environment.update(
                {
                    "PIP_DISABLE_PIP_VERSION_CHECK": "1",
                    "PIP_NO_INDEX": "1",
                    "PYTHONNOUSERSITE": "1",
                }
            )
            create = subprocess.run(
                [sys.executable, str(SCRIPT), "--venv", str(venv)],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(create.returncode, 0, create.stderr)

            version = "0.0.0+freeflow-missing"
            requirements = root / "requirements.txt"
            requirements.write_text(
                f"huggingface-hub=={version} \\\n"
                "    --hash=sha256:" + ("0" * 64) + "\n",
                encoding="utf-8",
            )
            digest = hashlib.sha256(requirements.read_bytes()).hexdigest()
            marker = venv / f".model-requirements-{digest}"
            marker.touch()
            provision = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--venv",
                    str(venv),
                    "--requirements",
                    str(requirements),
                    "--huggingface-version",
                    version,
                ],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(provision.returncode, 0)
            self.assertFalse(marker.exists())

    def test_final_venv_symlink_is_unlinked_without_touching_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            victim = root / "victim"
            victim.mkdir()
            sentinel = victim / "sentinel"
            sentinel.write_text("keep", encoding="utf-8")
            venv = root / "model-tools"
            venv.symlink_to(victim, target_is_directory=True)

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--venv", str(venv)],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
            self.assertFalse(venv.is_symlink())
            self.assertTrue((venv / ".ready").is_file())

    def test_symlinked_venv_parent_is_rejected_without_touching_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            victim = root / "victim"
            victim.mkdir()
            sentinel = victim / "sentinel"
            sentinel.write_text("keep", encoding="utf-8")
            work = root / "model-work"
            work.symlink_to(victim, target_is_directory=True)

            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--venv", str(work / "venv")],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("venv parent must be a real directory", result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
            self.assertFalse((victim / "venv").exists())


if __name__ == "__main__":
    unittest.main()
