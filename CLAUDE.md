# Instructions for Coding Agents

## App Name

The app is called "Unramble".

## File Formatting

- Every file must end with exactly one newline.
- No trailing whitespace on any line.

## Committed Artifacts

In source code, README, CLAUDE.md, and commit messages:
- describe only what the code is and what it does.
- do not mention planning docs, reference docs, or tracking docs.
- do not reference phase numbers, track names, or internal project tracking.

## Testing

The package contains XCTest and Swift Testing tests. Their native terminal summaries use different counting semantics, so use the Make targets below; the runner reports each framework separately and fails if either report is missing or inconsistent.

```bash
make test               # Default package selection; inherits explicit test gates.
make test-ci            # Bounded clean-CI selection; excludes host/live/model/corpus suites.
make test-all           # Default selection plus Keychain and slow timeout suites.
make test-runner-tests  # Runner/parser fixture checks; does not build the Swift package.
```

`make test-all` is not a literal all-tests lane. It enables only `UNRAMBLE_TEST_KEYCHAIN=1` and `UNRAMBLE_TEST_SLOW=1`; live OpenAI, local-model, dump, replay, benchmark, and compile-gated evaluation suites remain separately controlled.

The default selection includes corpus-backed polish scenario tests and expects the ignored `training/polish-tests.json` file. Generate it from the committed YAML before the default or Keychain/slow lane when starting from a clean checkout. The isolated environment below installs only the generator's PyYAML dependency, not the MLX training stack:

```bash
cd training
python3 -m venv ../.scratch/polish-data-venv
../.scratch/polish-data-venv/bin/pip install 'pyyaml>=6.0'
../.scratch/polish-data-venv/bin/python generate_training_data.py --no-casual --split
```

**Environment variable gates:**
- `UNRAMBLE_TEST_KEYCHAIN=1` — enables Keychain tests (KeychainServiceTests and
  ServiceConfigTests). These trigger macOS login Keychain password prompts.
- `UNRAMBLE_TEST_SLOW=1` — enables timeout tests (PipelineTimeoutTests ~75s) that
  use real timeouts and waits.
- `UNRAMBLE_TEST_OPENAI=1` — enables live tests that hit the real OpenAI API.
  Requires `OPENAI_API_KEY` to be set in the environment.
- `UNRAMBLE_TEST_OPENAI_BENCH=1` — enables the OpenAI Realtime latency benchmark
  suite (hits the real API, takes several seconds per run).

The first two are set automatically by `make test-all`.

By default, each invocation creates a unique directory under `.scratch/test-runs/` containing `swift-test.log`, `results-swift-testing.xml`, and `summary.txt`. The command prints those paths. Set `TEST_LOG` only when a caller needs an exact text-log path:

```bash
TEST_LOG=/tmp/unramble-focused.log make test
```

Run affected tests before the full suite, and keep their complete output:

```bash
cd UnrambleKit
mkdir -p ../.scratch/test-runs
set -o pipefail
swift test --filter "testNameA|testNameB" 2>&1 | tee ../.scratch/test-runs/focused.log
```

Run `make test` after the focused tests pass.

## Interactive Commands

Some git commands open an interactive pager that blocks terminal execution. Always pipe output
to prevent blocking:

```bash
git log --oneline -10 | cat
git diff | cat
git diff --stat | cat
git diff --name-only | cat
git show | cat
git branch -a | cat
```

Or use the `--no-pager` flag:

```bash
git --no-pager log --oneline -10
git --no-pager diff
```

## Git Workflow

- Commit working code as you go. Run the relevant focused tests and the appropriate package selection before each commit.
- `.scratch/` is gitignored.
- Use the `.scratch` directory for notes, temporary tests, or experimental code that should not
  be committed.
  - Create a dedicated subfolder within `.scratch` for each task (e.g., `.scratch/feature-name`).
  - Before creating a new subfolder, check if one already exists for the current work.

## Commit Messages

- Use imperative mood and active voice.
- Start the subject line with a verb: "Add", "Fix", "Update", "Remove", "Refactor".
- Keep the subject line under 50 characters.
- Capitalize the first letter of the subject line.
- Do not end the subject line with a period.
- Separate the subject from the body with a blank line.
- Wrap the body at 72 characters.
- Use the body to explain what and why, not how.
- Focus on the change itself, not the process of making it.
- Write as if completing the sentence: "If applied, this commit will..."
- Do not mention test counts or pass rates in commit messages.

## Writing Style

### Use Active Verb Forms

When writing comments, doc comments, commit messages, or documentation, prefer active verb
phrases over nominalized noun phrases.

Active verbs are clearer, more direct, and easier to scan.

| Avoid (Nominalized)               | Prefer (Active)                 |
|------------------------------------|---------------------------------|
| Audio buffer management            | Manage audio buffers            |
| Permission state checking          | Check permission state          |
| Recording state transition         | Transition recording state      |
| Context assembly and caching       | Assemble and cache context      |
| Text injection handling            | Inject text                     |

### Prefer "to + verb" Over "for + gerund"

When describing what a module or function does, use infinitive phrases:

| Avoid                                            | Prefer                                        |
|--------------------------------------------------|-----------------------------------------------|
| "provides methods for capturing audio"           | "provides methods to capture audio"           |
| "for reading accessibility attributes"           | "to read accessibility attributes"            |
| "for managing recording state transitions"       | "to manage recording state transitions"       |

### Where This Applies

- Function and method doc comments
- TODO comments
- Commit messages
- README sections
- Inline comments explaining intent

### Exceptions

Nominalized forms are acceptable for:
- Type names (`AudioProvider`, `PermissionManager`)
- Protocol names (`AudioProviding`, `TextInjecting`)
- Module names
- When the noun form is the actual domain term

### Quick Test

If you can ask "Who does what?" and rewrite to answer that question with a subject + verb,
use the active form.

## Running and Debugging the App

### Building

```bash
make generate   # Regenerate Xcode project (needed after adding/removing files)
make build      # Build via xcodebuild
make test       # Run the default package selection (see Testing section)
make clean      # Clean build artifacts + DerivedData
```

### Launching the app

In DEBUG builds, `OPENAI_API_KEY` in the process environment overrides the
Keychain-stored key so local development does not trigger Keychain password
prompts on every build.

Launch in the background and append output to a log file:

```bash
pkill -9 -f "Unramble.app/Contents/MacOS/Unramble" 2>/dev/null
sleep 1
APP=$(find ~/Library/Developer/Xcode/DerivedData/Unramble-*/Build/Products/Debug -name Unramble.app -maxdepth 1)
echo "=== $(date) ===" >> /tmp/unramble.log
OPENAI_API_KEY="sk-..." \
"$APP/Contents/MacOS/Unramble" >> /tmp/unramble.log 2>&1 &
echo "Launched PID $!"
```

Then tail or grep the log to follow activity:

```bash
tail -f /tmp/unramble.log
grep -E "Pipeline|AudioCapture|Streaming|polish" /tmp/unramble.log
```

### Logging

Use `Log.debug()` for all pipeline and streaming provider logging. It writes to
`FileHandle.standardError` which is line-buffered. **Do not use `debugPrint`** in these
paths — stdout is block-buffered when redirected to a file, hiding output during hangs.

## Documentation

Don't create too many summary documents and markdown files.
