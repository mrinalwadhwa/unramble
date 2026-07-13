#!/usr/bin/env python3

from __future__ import annotations

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
DOWNLOADER = SCRIPTS_DIR / "download-models.py"
VERIFIER = SCRIPTS_DIR / "verify-model-pack.py"

NEMOTRON_ID = "nemotron-speech-streaming-en-0.6b-coreml"
QWEN_ID = "qwen3-0.6b-4bit"
ADAPTER_ID = "qwen3-0.6b-4bit-polish-adapter"
ADAPTER_PATH = f"FreeFlowApp/Resources/models/{ADAPTER_ID}"

FAKE_HF = r'''#!/usr/bin/env python3
import base64
import json
import os
import sys
import time
from pathlib import Path


def append_json(path, value):
    payload = (json.dumps(value, separators=(",", ":")) + "\n").encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        if os.write(descriptor, payload) != len(payload):
            raise OSError("short append to fake hf log")
    finally:
        os.close(descriptor)


def main():
    if os.environ.get("FAKE_HF_FAIL_IF_CALLED") == "1":
        print("fake hf must not be called", file=sys.stderr)
        return 97

    arguments = sys.argv[1:]
    if len(arguments) < 2 or arguments[0] != "download":
        print(f"unsupported fake hf command: {arguments!r}", file=sys.stderr)
        return 64

    repo = arguments[1]
    revision = None
    local_dir = None
    includes = []
    index = 2
    while index < len(arguments):
        option = arguments[index]
        if option not in {"--revision", "--local-dir", "--include"}:
            print(f"unsupported fake hf option: {option}", file=sys.stderr)
            return 64
        if index + 1 >= len(arguments):
            print(f"missing value for fake hf option: {option}", file=sys.stderr)
            return 64
        value = arguments[index + 1]
        if option == "--revision":
            revision = value
        elif option == "--local-dir":
            local_dir = value
        else:
            includes.append(value)
        index += 2

    if revision is None or local_dir is None:
        print("fake hf requires --revision and --local-dir", file=sys.stderr)
        return 64

    fixture_path = Path(os.environ["FAKE_HF_FIXTURES"])
    fixtures = json.loads(fixture_path.read_text(encoding="utf-8"))
    if repo not in fixtures:
        print(f"unknown fake hf repository: {repo}", file=sys.stderr)
        return 65

    expected_paths = set(fixtures[repo])
    allow_unexpected = os.environ.get("FAKE_HF_ALLOW_UNEXPECTED_INCLUDES") == "1"
    if not allow_unexpected and (
        set(includes) != expected_paths or len(includes) != len(expected_paths)
    ):
        print(
            f"wrong includes for {repo}: expected {sorted(expected_paths)!r}, "
            f"found {includes!r}",
            file=sys.stderr,
        )
        return 66

    append_json(
        os.environ["FAKE_HF_LOG"],
        {"repo": repo, "revision": revision, "includes": includes},
    )
    parent_pid = os.getppid()
    event_log = os.environ["FAKE_HF_EVENT_LOG"]
    append_json(
        event_log,
        {
            "event": "start",
            "parentPid": parent_pid,
            "repo": repo,
            "timeNs": time.monotonic_ns(),
        },
    )
    delay = float(os.environ.get("FAKE_HF_DELAY", "0"))
    if delay > 0:
        time.sleep(delay)

    destination = Path(local_dir)
    corrupt = os.environ.get("FAKE_HF_CORRUPT")
    for relative_path in includes:
        encoded = fixtures[repo].get(relative_path)
        content = (
            base64.b64decode(encoded)
            if encoded is not None
            else b"unexpected manifest path\n"
        )
        if corrupt == f"{repo}:{relative_path}":
            content = bytes([content[0] ^ 1]) + content[1:]
        path = destination / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    for relative_path in (".cache/fake-metadata", ".huggingface/fake-metadata"):
        path = destination / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("must be removed", encoding="utf-8")
    append_json(
        event_log,
        {
            "event": "end",
            "parentPid": parent_pid,
            "repo": repo,
            "timeNs": time.monotonic_ns(),
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


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


@unittest.skipUnless(shutil.which("git"), "git is required by download-models.py")
class DownloadModelsIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.scripts_dir = self.root / "scripts"
        self.models_dir = self.root / "FreeFlowApp" / "Resources" / "models"
        self.manifest_path = self.root / "FreeFlowApp" / "models.json"
        self.fake_bin = self.root / "fake-bin"
        self.fake_hf_log = self.root / "fake-hf.jsonl"
        self.fake_hf_events = self.root / "fake-hf-events.jsonl"
        self.fake_hf_fixtures = self.root / "fake-hf-fixtures.json"

        self.scripts_dir.mkdir(parents=True)
        shutil.copy2(DOWNLOADER, self.scripts_dir / DOWNLOADER.name)
        shutil.copy2(VERIFIER, self.scripts_dir / VERIFIER.name)

        self.contents = {
            NEMOTRON_ID: {
                "nemotron_coreml_560ms/tokenizer.json": b"nemotron tokenizer\n",
                "nemotron_coreml_560ms/encoder/model.mil": b"nemotron encoder\n",
            },
            QWEN_ID: {
                "model.safetensors": b"qwen weights\n",
                "tokenizer.json": b"qwen tokenizer\n",
            },
            ADAPTER_ID: {
                "adapter_config.json": b'{"rank":8}\n',
                "adapters.safetensors": b"adapter weights\n",
            },
        }
        self.hf_sources = {
            NEMOTRON_ID: {
                "repo": "fixture/nemotron",
                "revision": "1" * 40,
            },
            QWEN_ID: {
                "repo": "fixture/qwen",
                "revision": "2" * 40,
            },
        }

        self._write_model(ADAPTER_ID)
        self._initialize_git_repository()
        self.adapter_revision = self._git("rev-parse", "HEAD").stdout.strip()
        self._write_manifest()
        self._write_fake_hf()

        adapter_root = self.models_dir / ADAPTER_ID
        (adapter_root / "adapter_config.json").write_bytes(b"dirty config\n")
        (adapter_root / "adapters.safetensors").write_bytes(b"dirty weights\n")
        (adapter_root / "dirty-only.bin").write_bytes(b"not committed\n")
        stale = self.models_dir / "stale-model" / "stale.bin"
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b"old pack must survive failed staging\n")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @property
    def downloader(self) -> Path:
        return self.scripts_dir / DOWNLOADER.name

    def _git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=True,
        )

    def _initialize_git_repository(self) -> None:
        self._git("init", "-q")
        self._git("config", "user.name", "FreeFlow Test")
        self._git("config", "user.email", "freeflow-test@example.invalid")
        self._git("config", "commit.gpgsign", "false")
        self._git("add", "--", ADAPTER_PATH)
        self._git("commit", "-q", "-m", "Pin adapter fixture")

    def _file_records(self, model_id: str) -> list[dict[str, object]]:
        return [
            {"path": path, "size": len(content), "sha256": sha256(content)}
            for path, content in self.contents[model_id].items()
        ]

    def _write_manifest(self) -> None:
        nemotron_files = self._file_records(NEMOTRON_ID)
        qwen_files = self._file_records(QWEN_ID)
        adapter_files = self._file_records(ADAPTER_ID)
        manifest = {
            "schemaVersion": 1,
            "models": {
                NEMOTRON_ID: {
                    "role": "speech-to-text",
                    "source": {
                        "type": "huggingface",
                        **self.hf_sources[NEMOTRON_ID],
                    },
                    "treeSha256": tree_sha256(nemotron_files),
                    "files": nemotron_files,
                },
                QWEN_ID: {
                    "role": "language-model",
                    "source": {
                        "type": "huggingface",
                        **self.hf_sources[QWEN_ID],
                    },
                    "treeSha256": tree_sha256(qwen_files),
                    "files": qwen_files,
                },
                ADAPTER_ID: {
                    "role": "polish-adapter",
                    "source": {
                        "type": "repository",
                        "path": ADAPTER_PATH,
                        "revision": self.adapter_revision,
                    },
                    "requires": {
                        "model": QWEN_ID,
                        "treeSha256": tree_sha256(qwen_files),
                    },
                    "treeSha256": tree_sha256(adapter_files),
                    "files": adapter_files,
                },
            },
        }
        self.manifest_path.parent.mkdir(parents=True, exist_ok=True)
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    def _write_fake_hf(self) -> None:
        fixture = {
            source["repo"]: {
                path: base64.b64encode(content).decode("ascii")
                for path, content in self.contents[model_id].items()
            }
            for model_id, source in self.hf_sources.items()
        }
        self.fake_hf_fixtures.write_text(json.dumps(fixture), encoding="utf-8")
        self.fake_bin.mkdir()
        fake_hf = self.fake_bin / "hf"
        fake_hf.write_text(FAKE_HF, encoding="utf-8")
        fake_hf.chmod(0o755)

    def _write_model(self, model_id: str) -> None:
        for relative_path, content in self.contents[model_id].items():
            path = self.models_dir / model_id / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)

    def _write_exact_pack(self) -> None:
        if self.models_dir.exists():
            shutil.rmtree(self.models_dir)
        for model_id in self.contents:
            self._write_model(model_id)

    def _process_environment(
        self, overrides: dict[str, str] | None = None
    ) -> dict[str, str]:
        process_environment = os.environ.copy()
        process_environment.update(
            {
                "PATH": f"{self.fake_bin}{os.pathsep}{process_environment['PATH']}",
                "FAKE_HF_EVENT_LOG": str(self.fake_hf_events),
                "FAKE_HF_FIXTURES": str(self.fake_hf_fixtures),
                "FAKE_HF_LOG": str(self.fake_hf_log),
            }
        )
        if overrides:
            process_environment.update(overrides)
        return process_environment

    def _run_downloader(
        self, *arguments: str, environment: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(self.downloader), *arguments],
            cwd=self.root,
            env=self._process_environment(environment),
            text=True,
            capture_output=True,
            check=False,
        )

    def _run_verifier(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(self.scripts_dir / VERIFIER.name),
                "--manifest",
                str(self.manifest_path),
                "--models-dir",
                str(self.models_dir),
            ],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
        )

    def _remove_models_path(self) -> None:
        if self.models_dir.is_symlink() or self.models_dir.is_file():
            self.models_dir.unlink()
        elif self.models_dir.exists():
            shutil.rmtree(self.models_dir)

    def _assert_no_model_work_residue(self) -> None:
        work_dir = self.root / "FreeFlowApp" / ".model-work"
        self.assertEqual(list(work_dir.glob("staging-*")), [])
        self.assertEqual(list(work_dir.glob("backup-*")), [])

    def test_symlinked_work_directory_is_rejected_without_cleanup(self) -> None:
        self._write_exact_pack()
        victim = self.root / "victim-work"
        staging = victim / "staging-keep"
        staging.mkdir(parents=True)
        sentinel = staging / "sentinel"
        sentinel.write_text("keep", encoding="utf-8")
        work_dir = self.root / "FreeFlowApp" / ".model-work"
        work_dir.symlink_to(victim, target_is_directory=True)

        result = self._run_downloader("--verify")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("model work directory must be a real directory", result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        self.assertEqual(list(work_dir.glob("manifest-*.json")), [])

    def _wait_until(self, predicate, message: str, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.01)
        self.fail(message)

    def _hf_calls(self) -> list[dict[str, object]]:
        return self._json_lines(self.fake_hf_log)

    def _hf_events(self) -> list[dict[str, object]]:
        return self._json_lines(self.fake_hf_events)

    @staticmethod
    def _json_lines(path: Path) -> list[dict[str, object]]:
        if not path.exists():
            return []
        return [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
        ]

    def _pack_snapshot(self) -> dict[str, tuple[str, bytes]]:
        snapshot: dict[str, tuple[str, bytes]] = {}
        for path in sorted(self.models_dir.rglob("*")):
            relative_path = path.relative_to(self.models_dir).as_posix()
            if path.is_dir():
                snapshot[relative_path] = ("directory", b"")
            else:
                snapshot[relative_path] = ("file", path.read_bytes())
        return snapshot

    def test_verify_is_network_free(self) -> None:
        self._write_exact_pack()

        result = self._run_downloader(
            "--verify", environment={"FAKE_HF_FAIL_IF_CALLED": "1"}
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified 3 models, 6 files", result.stdout)
        self.assertEqual(self._hf_calls(), [])

    def test_successful_materialization_uses_exact_hf_pins_and_replaces_pack(self) -> None:
        result = self._run_downloader("--force")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self._hf_calls(),
            [
                {
                    "repo": self.hf_sources[NEMOTRON_ID]["repo"],
                    "revision": self.hf_sources[NEMOTRON_ID]["revision"],
                    "includes": list(self.contents[NEMOTRON_ID]),
                },
                {
                    "repo": self.hf_sources[QWEN_ID]["repo"],
                    "revision": self.hf_sources[QWEN_ID]["revision"],
                    "includes": list(self.contents[QWEN_ID]),
                },
            ],
        )
        self.assertEqual(
            {path.name for path in self.models_dir.iterdir()}, set(self.contents)
        )
        self.assertFalse((self.models_dir / "stale-model").exists())
        self.assertFalse(any(self.models_dir.rglob(".cache")))
        self.assertFalse(any(self.models_dir.rglob(".huggingface")))

    def test_regular_file_at_models_path_is_replaced_and_backup_is_cleaned(self) -> None:
        self._remove_models_path()
        self.models_dir.write_bytes(b"not a model directory\n")

        result = self._run_downloader("--force")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.models_dir.is_dir())
        self.assertFalse(self.models_dir.is_symlink())
        verify = self._run_verifier()
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self._assert_no_model_work_residue()

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are not supported")
    def test_symlink_at_models_path_is_replaced_without_touching_target(self) -> None:
        outside = self.root / "outside-model-target"
        outside.mkdir()
        sentinel = outside / "sentinel.txt"
        sentinel.write_bytes(b"outside must remain untouched\n")
        self._remove_models_path()
        self.models_dir.symlink_to(outside, target_is_directory=True)

        result = self._run_downloader("--force")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.models_dir.is_dir())
        self.assertFalse(self.models_dir.is_symlink())
        self.assertEqual(sentinel.read_bytes(), b"outside must remain untouched\n")
        verify = self._run_verifier()
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self._assert_no_model_work_residue()

    def test_concurrent_force_materializations_are_serialized(self) -> None:
        environment = self._process_environment({"FAKE_HF_DELAY": "0.08"})
        command = [sys.executable, str(self.downloader), "--force"]
        processes: list[subprocess.Popen[str]] = []
        outputs: list[tuple[str, str]] = []
        try:
            for _ in range(2):
                processes.append(
                    subprocess.Popen(
                        command,
                        cwd=self.root,
                        env=environment,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                )
            for process in processes:
                outputs.append(process.communicate(timeout=10))
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
                f"concurrent materializer failed\nstdout:\n{stdout}\nstderr:\n{stderr}",
            )

        calls = self._hf_calls()
        nemotron_repo = self.hf_sources[NEMOTRON_ID]["repo"]
        qwen_repo = self.hf_sources[QWEN_ID]["repo"]
        self.assertEqual(
            [call["repo"] for call in calls],
            [nemotron_repo, qwen_repo, nemotron_repo, qwen_repo],
        )

        events = sorted(self._hf_events(), key=lambda event: int(event["timeNs"]))
        parent_ids = {int(event["parentPid"]) for event in events}
        self.assertEqual(len(events), 8, events)
        self.assertEqual(len(parent_ids), 2, events)
        intervals = []
        for parent_id in parent_ids:
            parent_events = [
                event for event in events if int(event["parentPid"]) == parent_id
            ]
            self.assertEqual(
                [event["event"] for event in parent_events],
                ["start", "end", "start", "end"],
                parent_events,
            )
            intervals.append(
                (
                    int(parent_events[0]["timeNs"]),
                    int(parent_events[-1]["timeNs"]),
                )
            )
        intervals.sort()
        self.assertLessEqual(intervals[0][1], intervals[1][0], events)

        work_dir = self.root / "FreeFlowApp" / ".model-work"
        self.assertEqual(list(work_dir.glob("staging-*")), [])
        self.assertEqual(list(work_dir.glob("backup-*")), [])
        verify = subprocess.run(
            [
                sys.executable,
                str(self.scripts_dir / VERIFIER.name),
                "--manifest",
                str(self.manifest_path),
                "--models-dir",
                str(self.models_dir),
            ],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.assertIn("Verified 3 models, 6 files", verify.stdout)
        self.assertEqual(len(self._hf_calls()), 4)
        self.assertEqual(list(work_dir.glob("staging-*")), [])
        self.assertEqual(list(work_dir.glob("backup-*")), [])

    def test_run_verifies_before_and_after_while_blocking_force(self) -> None:
        self._write_exact_pack()
        command_started = self.root / "run-command-started"
        command_finished = self.root / "run-command-finished"
        child_code = (
            "import sys,time\n"
            "from pathlib import Path\n"
            "Path(sys.argv[1]).write_text(str(time.monotonic_ns()), encoding='utf-8')\n"
            "time.sleep(0.25)\n"
            "Path(sys.argv[2]).write_text(str(time.monotonic_ns()), encoding='utf-8')\n"
        )
        run_process = subprocess.Popen(
            [
                sys.executable,
                str(self.downloader),
                "--run",
                sys.executable,
                "-c",
                child_code,
                str(command_started),
                str(command_finished),
            ],
            cwd=self.root,
            env=self._process_environment({"FAKE_HF_FAIL_IF_CALLED": "1"}),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        force_process: subprocess.Popen[str] | None = None
        try:
            self._wait_until(
                command_started.is_file,
                "--run child command did not start",
            )
            force_process = subprocess.Popen(
                [sys.executable, str(self.downloader), "--force"],
                cwd=self.root,
                env=self._process_environment({"FAKE_HF_DELAY": "0.05"}),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            time.sleep(0.1)
            self.assertIsNone(force_process.poll())
            self.assertEqual(self._hf_events(), [])
            run_stdout, run_stderr = run_process.communicate(timeout=10)
            force_stdout, force_stderr = force_process.communicate(timeout=10)
        finally:
            for process in (run_process, force_process):
                if process is not None and process.poll() is None:
                    process.terminate()
            for process in (run_process, force_process):
                if process is not None and process.poll() is None:
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()

        self.assertEqual(
            run_process.returncode,
            0,
            f"stdout:\n{run_stdout}\nstderr:\n{run_stderr}",
        )
        assert force_process is not None
        self.assertEqual(
            force_process.returncode,
            0,
            f"stdout:\n{force_stdout}\nstderr:\n{force_stderr}",
        )
        self.assertEqual(run_stdout.count("Verified 3 models, 6 files"), 2)
        self.assertTrue(command_finished.is_file())
        events = sorted(self._hf_events(), key=lambda event: int(event["timeNs"]))
        self.assertEqual(len(events), 4, events)
        self.assertGreaterEqual(
            int(events[0]["timeNs"]),
            int(command_finished.read_text(encoding="utf-8")),
        )
        verify = self._run_verifier()
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self._assert_no_model_work_residue()

    def test_failed_downloaded_bytes_preserve_old_pack(self) -> None:
        before = self._pack_snapshot()
        corrupt = f"{self.hf_sources[QWEN_ID]['repo']}:model.safetensors"

        result = self._run_downloader(
            "--force", environment={"FAKE_HF_CORRUPT": corrupt}
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertEqual(self._pack_snapshot(), before)
        work_dir = self.root / "FreeFlowApp" / ".model-work"
        self.assertEqual(list(work_dir.glob("staging-*")), [])
        self.assertEqual(list(work_dir.glob("backup-*")), [])

    def test_manifest_change_during_download_preserves_pack_and_cannot_escape(
        self,
    ) -> None:
        before = self._pack_snapshot()
        malicious_path = "../../../../escaped-model-file"
        escaped_path = self.root / "escaped-model-file"
        process = subprocess.Popen(
            [sys.executable, str(self.downloader), "--force"],
            cwd=self.root,
            env=self._process_environment(
                {
                    "FAKE_HF_ALLOW_UNEXPECTED_INCLUDES": "1",
                    "FAKE_HF_DELAY": "0.15",
                }
            ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            self._wait_until(
                lambda: bool(self._hf_events()),
                "materializer did not start the delayed Hugging Face download",
            )
            changed_manifest = json.loads(
                self.manifest_path.read_text(encoding="utf-8")
            )
            changed_manifest["models"][QWEN_ID]["files"][0]["path"] = malicious_path
            self.manifest_path.write_text(
                json.dumps(changed_manifest), encoding="utf-8"
            )
            stdout, stderr = process.communicate(timeout=10)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

        self.assertEqual(
            process.returncode,
            1,
            f"stdout:\n{stdout}\nstderr:\n{stderr}",
        )
        self.assertIn("model manifest changed during materialization", stderr)
        self.assertEqual(self._pack_snapshot(), before)
        self.assertFalse(escaped_path.exists())
        downloaded_paths = {
            path for call in self._hf_calls() for path in call["includes"]
        }
        self.assertNotIn(malicious_path, downloaded_paths)
        self._assert_no_model_work_residue()

    def test_unknown_flag_fails_before_hf(self) -> None:
        result = self._run_downloader(
            "--unknown", environment={"FAKE_HF_FAIL_IF_CALLED": "1"}
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments: --unknown", result.stderr)
        self.assertEqual(self._hf_calls(), [])

    def test_repository_artifact_uses_pinned_commit_not_dirty_worktree(self) -> None:
        adapter_root = self.models_dir / ADAPTER_ID
        self.assertEqual(
            (adapter_root / "adapters.safetensors").read_bytes(), b"dirty weights\n"
        )
        self.assertTrue((adapter_root / "dirty-only.bin").exists())

        result = self._run_downloader("--force")

        self.assertEqual(result.returncode, 0, result.stderr)
        for relative_path, expected_content in self.contents[ADAPTER_ID].items():
            self.assertEqual(
                (self.models_dir / ADAPTER_ID / relative_path).read_bytes(),
                expected_content,
            )
        self.assertFalse((self.models_dir / ADAPTER_ID / "dirty-only.bin").exists())
        self.assertIn(self.adapter_revision, result.stdout)


if __name__ == "__main__":
    unittest.main()
