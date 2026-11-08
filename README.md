# OpenSpec auto-mode

Implements, tests and archives prepared OpenSpec changes one after another, unattended, in any project.

The core idea: **every agent run is a new Claude Code process with an empty context.** Nothing is carried between runs through the conversation, only through files (OpenSpec artifacts, code, git). A large change is split across several runs, so the context window never fills up and the agent does not start hallucinating.

```
openspec-auto.ps1 (deterministic script)
  testCommand once: must be green before anything starts
  for each change 01-…, 02-…, …:
    branch auto/NN-name (chained from the previous one)
    ┌─ new process: claude -p --agent openspec-auto   ← empty context
    │    implements one task group of tasks.md (at most tasksPerRun tasks), commits, exits
    ├─ script verifies the files (git status, validate, archive/BLOCKED.md, push)
    ├─ group complete? → script runs testCommand; red → next run repairs only that group
    ├─ not done yet and progress was made? → again, new process
    ├─ all groups green → short final run archives the change
    └─ archived? → script runs testCommand itself (the agent's word is not enough)
         NONCRITICAL + red tests → fix-NN-name right away, new process, same branch
  report → .openspec-auto/auto-mode-report.md
```

**Step-by-step guide: [GUIDE.md](GUIDE.md).**

## How the work is verified

The agent never grades itself. Its final message ("SUCCESS") is ignored; the script decides from evidence a program produces:

| Evidence | Checked by the script |
|---|---|
| tests exit 0 | before the first change, after every task group, after every archived change |
| acceptance tests exit 0 (optional) | tests written before the change and frozen: after its last task group, after archiving, and for all earlier changes again (regression) |
| acceptance tests unchanged | `git diff` of the acceptance folder after every run is empty |
| everything written down | `git status` clean, `openspec validate` passes, archive or `BLOCKED.md` present |
| progress | more tasks ticked, or a red group repaired; otherwise the loop stops |
| nothing left the machine | remote refs unchanged (no push) |

When a check fails, only the failing unit goes back to a fresh agent, with the test output and a file scope, and with a hard limit on attempts (`maxGroupRepairs`, `maxRunsPerFix`). After that a human decides. Architectural questions are never decided by the agent: it writes `BLOCKED.md` with options and the loop stops.

Limit: tests prove that nothing *known* broke. The agent is told never to weaken or delete tests, but only acceptance tests (below) are technically protected: tests the agent writes during a change can still be changed by it. Background: [docs/hardening-plan.md](docs/hardening-plan.md).

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
| `testCommand` | test command (required); the agent runs it, and the script runs it itself at start, after every task group and after every archived change | – |
| `allowedCommands` | additional commands the agent may run (build, lint…) | `[]` |
| `tasksPerRun` | max. tasks from `tasks.md` per run (one context) | 8 |
| `maxRunsPerChange` | max. runs per change | 10 |
| `timeoutMinutes` | time limit of one run | 60 |
| `maxTurns` | max. agent turns in one run | 200 |
| `model`, `effort` | model and reasoning effort for Claude Code | Claude Code default |
| `maxBudgetUsdPerRun` | cost cap of one run | no limit |
| `testTimeoutMinutes` | time limit of one test run by the script | 20 |
| `groupTesting` | one task group (`## N. …` in `tasks.md`) per run, the script tests after every group, archiving in a separate final run; `false` = one pass, tests only at the end | `true` |
| `maxGroupRepairs` | repair runs for a group whose tests are red when it is complete | 2 |
| `fixMode` | `immediate`: after a NONCRITICAL with failing tests, process its `fix-NN-name` right away; `stop`: stop the loop instead | `immediate` |
| `maxRunsPerFix` | max. runs for one `fix-NN-name` change | 2 |
| `acceptanceMode` | `reviewed`: every numbered change needs acceptance tests in `acceptanceDir/<change>/`, written before the start (with Claude) and reviewed by you; `off`: none | `off` |
| `acceptanceCommand` | runs the acceptance tests of one change; `{change}` is replaced by its name, e.g. `node --test "acceptance/{change}/*.accept.js"` | - |
| `acceptanceDir` | folder of the acceptance tests (frozen for the agent) | `acceptance` |

Recommended: `.gitattributes` with `* text=auto eol=lf` (otherwise line-ending conversions can make `git status` falsely dirty).

The tests must pass and must not leave files behind (add test outputs such as coverage reports to `.gitignore`), otherwise the script refuses to start. A script in the project root needs an explicit path (`.\test.cmd`, not `test.cmd`): Claude Code sets `NoDefaultCurrentDirectoryInExePath`, so Windows does not find programs in the current directory by name.

### Writing `tasks.md` for task groups

With `groupTesting`, every group is one agent run followed by a test run of the script, so a group should be a logical unit that ends in a working state and brings its own tests:

```markdown
## 1. Slugify (code + tests)
- [ ] 1.1 Add `slugify(text)` to `src/text.js` and export it
- [ ] 1.2 Add `tests/slugify.test.js`, one test per scenario of the spec

## 2. Truncate (code + tests)
- [ ] 2.1 …
```

Avoid "1. Implementation / 2. Tests": the check after group 1 would test nothing new. A change needs at least one run per group plus the final run; the script refuses to start when `maxRunsPerChange` is too small.

### Acceptance tests (optional, `acceptanceMode: reviewed`)

Acceptance tests say when a change is done, and they exist before the agent writes any code. You write them with Claude during propose and review them, one test per scenario of the spec deltas, into `acceptance/<change>/`, and commit them with the proposal. They fail until the change is implemented.

Two ways to write them:
- **As part of the OpenSpec workflow (recommended):** `openspec-auto.ps1 -SetupAcceptanceSchema` copies OpenSpec's built-in `spec-driven` schema to `openspec/schemas/spec-driven-acceptance/`, adds an `acceptance` artifact between `design` and `tasks` and selects the schema in `openspec/config.yaml`. `/opsx:propose` then writes the tests and `acceptance.md` (table scenario -> test) for every new change and asks you to review them; the start check refuses a change without `acceptance.md`. OpenSpec custom schemas are experimental: after an OpenSpec update, run `-SetupAcceptanceSchema` again (it starts from the current built-in schema; edits of that folder are overwritten). Changes created before keep their schema; `fix-…` changes use the built-in `spec-driven` (they are checked against the acceptance tests of the change they fix).
- **Separately:** `/openspec-auto acceptance 01-login` after propose.

- The agent may not edit `acceptance/` (deny rules), and the script checks after every run that no commit touched it. A change there stops the loop (FAILED-CHECK).
- The script runs them when the last task group is done (red: repair run with the output), after archiving, and the tests of all archived changes before the start and after every archive.
- If the agent thinks an acceptance test is wrong, it stops with `BLOCKED.md`; you decide.
- `testCommand` must not pick them up, otherwise the tests of changes not yet implemented make the start red. With `node --test`, which finds `**/*.test.js`, name them `*.accept.js`. Run them directly (`node --test ...`), not through a `package.json` script: the agent can edit `package.json`, but not `openspec/auto-mode.json`.
- What they cannot prevent: an implementation fitted to the test inputs, or changes to helper files the tests import from outside `acceptance/`. Keep acceptance tests self-contained and use more than one example per scenario.

## Usage

1. Prepare the changes interactively (`/opsx:propose`) and name them in order: `01-login`, `02-profile`, … It does not have to be the whole project, a batch is enough; add more changes later and run again.
2. Commit them; the working tree must be clean.
3. Run it (start with `-DryRun` if you like). At start it checks that every numbered change has a complete proposal: all artifacts, at least one task in `tasks.md`, and `openspec validate` passes. If not, nothing runs and it lists what is missing where.

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\openspec-auto-mode\openspec-auto.ps1   # in the project root
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -DryRun                      # checks and plan only
powershell -ExecutionPolicy Bypass -File ...openspec-auto.ps1 -SetupAcceptanceSchema       # acceptance artifact in the OpenSpec workflow
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -Project C:\other\project
```

## Results

| Result | What happens |
|---|---|
| SUCCESS | change implemented and archived, the script's own test run passes → next change |
| NONCRITICAL | archived + a `fix-NN-name` change describing the bug is created. Tests green (bug not visible to tests): the fix waits for you → next change. Tests red: the script processes the fix right away on the same branch (at most `maxRunsPerFix` runs, done = tests green) → next change, or **stop** if the fix does not pass |
| BLOCKED | architectural problem, `openspec/changes/NN-name/BLOCKED.md`, not archived → **stop** |
| FAILED-CHECK | a script check failed (uncommitted changes, invalid specs, push attempt, crash, timeout, no progress, tests fail after archiving) → **stop** |
| STOPPED | a limit was reached (`maxRunsPerChange`, `maxRunsPerFix`, a group still red after `maxGroupRepairs` repair runs) → **stop** |

The notes column shows the test result of every task group, e.g. `groups: 1 green, 2 red->green (1 repair)`.

Report: `.openspec-auto/auto-mode-report.md`, logs of every run: `.openspec-auto/runs/<time>/`. The folder is listed in `.git/info/exclude`, so it never gets into the repository.

Nothing is pushed or merged. You review and merge the `auto/NN-…` branches yourself.

## After a stop

The script keeps no state of its own; re-running is the same command.

- **BLOCKED:** stay on `auto/NN-name`, resolve the problem (e.g. `/opsx:update NN-name`, install a package, edit `design.md`), delete `BLOCKED.md`, commit, run again. While `BLOCKED.md` exists, the script refuses to start.
- **FAILED-CHECK:** check the report and the run log, fix the state (commit or revert), run again from the current branch. The tests must be green again before the next start.
- **Interrupted fix:** if a `fix-NN-name` run was interrupted (crash, timeout), run again from `auto/NN-name`; the script resumes the fix even though the tests are still red.
- **`fix-…` changes waiting for you** (tests were green, `fixMode: stop`, or written by hand) are not processed by the loop. Implement them interactively (`/opsx:apply fix-NN-name`), or rename them to a numbered change.

## Cost

Every run is a full Claude Code session on your account: with a Claude subscription it counts toward your plan's usage limits, with an API key it is billed. The cost shown in the report comes from Claude Code itself. Measured on a small Node project with `sonnet`: about USD 0.15–0.20 per change in one pass (`groupTesting: false`), about USD 0.38 for a change with two task groups (three runs). Set a cap with `maxBudgetUsdPerRun`. The tests in `tests/` use a fake agent and make no API calls.

## Safety

- The agent runs in `dontAsk` mode: it may only do what is on the allowlist (file tools, `openspec`, local git without branch operations, `testCommand` and `allowedCommands`).
- Push is blocked by three layers: deny rules, a `pre-push` hook active when `OPENSPEC_AUTO_MODE=1`, and a check of remote refs after every run.
- The agent must not modify `.git/`, `.claude/`, `.openspec-auto/`, `openspec/auto-mode.json` or, with `acceptanceMode`, the acceptance folder (also checked with `git diff` after every run).
- `claude -p` skips the folder trust dialog. Only run it in projects you trust.

## Files

| File | Purpose |
|---|---|
| `openspec-auto.ps1` | control script (loop, checks, report) |
| `worker-prompt.md` | instructions for the agent of a single run |
| `install.ps1` | installs the `/openspec-auto` skill for the current user |
| `claude-skill/openspec-auto/SKILL.md` | skill source (`install.ps1` fills in the runner path) |
| `templates/auto-mode.json` | project configuration template |
| `tests/run-tests.ps1`, `tests/fake-claude.ps1` | tests of the loop logic with a fake agent (no API calls) |
| `GUIDE.md` | step-by-step guide |
| `docs/hardening-plan.md` | design notes: why the script verifies the agent, decisions, and the roadmap |

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

## License

[MIT](LICENSE)
