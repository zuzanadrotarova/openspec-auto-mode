# OpenSpec auto-mode

Implements, tests and archives prepared OpenSpec changes one after another, unattended, in any project.

The core idea: **every agent run is a new Claude Code process with an empty context.** Nothing is carried between runs through the conversation, only through files (OpenSpec artifacts, code, git). A large change is split across several runs, so the context window never fills up and the agent does not start hallucinating.

```
openspec-auto.ps1 (deterministic script)
  for each change 01-…, 02-…, …:
    branch auto/NN-name (chained from the previous one)
    ┌─ new process: claude -p --agent openspec-auto   ← empty context
    │    implements at most tasksPerRun tasks, commits, exits
    ├─ script verifies the files (git status, validate, archive/BLOCKED.md, push)
    └─ not done yet and progress was made? → again, new process
  report → .openspec-auto/auto-mode-report.md
```

**Step-by-step guide: [GUIDE.md](GUIDE.md).**

## Using it from Claude Code (recommended)

The `/openspec-auto` skill (`init`, `check`, `run`, `report`) runs the runner for you and summarizes the result. Installation (once per machine):

```powershell
git clone https://github.com/zuzanadrotarova/openspec-auto-mode.git
cd openspec-auto-mode
powershell -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1` installs the skill into `~/.claude/skills/openspec-auto/` and points it to the runner in this repository. Then restart Claude Code. Do not move the repository after installing (or run `install.ps1` again). To update: `git pull`, and if `claude-skill/` changed, run `install.ps1` again.

Typical flow:

```
/openspec-auto init                  # once per project
/opsx:propose 01-name: …             # one per change (01-, 02-, … = order)
"commit the proposals"
/openspec-auto check                 # readiness check
/openspec-auto run                   # runs in the background, summary at the end
"merge it into main"                 # after you review the result
```

The rest of this README describes running the runner directly.

## Requirements

- Windows PowerShell 5.1+ (or PowerShell 7)
- [Claude Code](https://claude.com/claude-code) (`claude`) and [OpenSpec](https://github.com/Fission-AI/OpenSpec) (`openspec`) on PATH
- git

## Project setup (once)

```powershell
cd C:\path\to\project
openspec init                     # if the project does not use OpenSpec yet
powershell -ExecutionPolicy Bypass -File C:\path\to\openspec-auto-mode\openspec-auto.ps1 -Init
```

`-Init` creates `openspec/auto-mode.json`. Edit it and commit it:

| Key | Meaning | Default |
|---|---|---|
| `testCommand` | test command (required) | – |
| `allowedCommands` | additional commands the agent may run (build, lint…) | `[]` |
| `tasksPerRun` | max. tasks from `tasks.md` per run (one context) | 8 |
| `maxRunsPerChange` | max. runs per change | 10 |
| `timeoutMinutes` | time limit of one run | 60 |
| `maxTurns` | max. agent turns in one run | 200 |
| `model`, `effort` | model and reasoning effort for Claude Code | Claude Code default |
| `maxBudgetUsdPerRun` | cost cap of one run | no limit |

Recommended: `.gitattributes` with `* text=auto eol=lf` (otherwise line-ending conversions can make `git status` falsely dirty).

## Usage

1. Prepare the changes interactively (`/opsx:propose`) and name them in order: `01-login`, `02-profile`, … It does not have to be the whole project, a batch is enough; add more changes later and run again.
2. Commit them; the working tree must be clean.
3. Run it (start with `-DryRun` if you like). At start it checks that every numbered change has a complete proposal: all artifacts, at least one task in `tasks.md`, and `openspec validate` passes. If not, nothing runs and it lists what is missing where.

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\openspec-auto-mode\openspec-auto.ps1   # in the project root
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -DryRun                      # checks and plan only
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -Project C:\other\project
```

## Results

| Result | What happens |
|---|---|
| SUCCESS | change implemented, tests pass, archived → next change |
| NONCRITICAL | archived + a `fix-NN-name` change describing the bug is created (not implemented) → next change |
| BLOCKED | architectural problem, `openspec/changes/NN-name/BLOCKED.md`, not archived → **stop** |
| FAILED-CHECK | a script check failed (uncommitted changes, invalid specs, push attempt, crash, timeout, no progress) → **stop** |

Report: `.openspec-auto/auto-mode-report.md`, logs of every run: `.openspec-auto/runs/<time>/`. The folder is listed in `.git/info/exclude`, so it never gets into the repository.

Nothing is pushed or merged. You review and merge the `auto/NN-…` branches yourself.

## After a stop

The script keeps no state of its own; re-running is the same command.

- **BLOCKED:** stay on `auto/NN-name`, resolve the problem (e.g. `/opsx:update NN-name`, install a package, edit `design.md`), delete `BLOCKED.md`, commit, run again. While `BLOCKED.md` exists, the script refuses to start.
- **FAILED-CHECK:** check the report and the run log, fix the state (commit or revert), run again from the current branch.
- **`fix-…` changes** are not processed by the loop. Implement them interactively (`/opsx:apply fix-NN-name`), or rename them to a numbered change.

## Safety

- The agent runs in `dontAsk` mode: it may only do what is on the allowlist (file tools, `openspec`, local git without branch operations, `testCommand` and `allowedCommands`).
- Push is blocked by three layers: deny rules, a `pre-push` hook active when `OPENSPEC_AUTO_MODE=1`, and a check of remote refs after every run.
- The agent must not modify `.git/`, `.claude/`, `.openspec-auto/` or `openspec/auto-mode.json`.
- `claude -p` skips the folder trust dialog. Only run it in projects you trust.

## Files

| File | Purpose |
|---|---|
| `openspec-auto.ps1` | control script (loop, checks, report) |
| `worker-prompt.md` | instructions for the agent of a single run |
| `install.ps1` | installs the `/openspec-auto` skill for the current user |
| `claude-skill/openspec-auto/SKILL.md` | skill source (`install.ps1` fills in the runner path) |
| `templates/auto-mode.json` | project configuration template |
| `tests/run-tests.ps1` | tests of the loop logic with a fake agent (no API calls) |
| `GUIDE.md` | step-by-step guide |

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```
