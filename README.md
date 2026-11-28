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

The `/openspec-auto` skill (`init`, `check`, `run`, `report`) runs the runner for you and summarizes the result. `init` also detects the stack and proposes memory settings (`memoryCleanupCommands`, `keepProcesses`, optional limits such as `org.gradle.jvmargs`); `run` first shows a read-only night checklist (biggest processes and commit charge, GPU driver auto-updates, Windows Update pause and active hours). Installation (once per machine):

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
| `maxTurns` | max. agent turns in one run; reaching it is a *limit stop* (see Outcomes) | 200 |
| `model`, `effort` | model and reasoning effort for Claude Code | Claude Code default |
| `maxBudgetUsdPerRun` | cost cap of one run; reaching it is a *limit stop*; recommended for unattended runs | no limit |
| `testTimeoutMinutes` | time limit of one test run by the script | 20 |
| `groupTesting` | one task group (`## N. …` in `tasks.md`) per run, the script tests after every group, archiving in a separate final run; `false` = one pass, tests only at the end | `true` |
| `maxGroupRepairs` | repair runs for a group whose tests are red when it is complete | 2 |
| `fixMode` | `immediate`: after a NONCRITICAL with failing tests, process its `fix-NN-name` right away; `stop`: stop the loop instead | `immediate` |
| `maxRunsPerFix` | max. runs for one `fix-NN-name` change | 2 |
| `acceptanceMode` | `reviewed`: every numbered change needs acceptance tests in `acceptanceDir/<change>/`, written before the start (with Claude) and reviewed by you; `off`: none | `off` |
| `acceptanceCommand` | runs the acceptance tests of one change; `{change}` is replaced by its name, e.g. `node --test "acceptance/{change}/*.accept.js"` | - |
| `acceptanceDir` | folder of the acceptance tests (frozen for the agent) | `acceptance` |
| `scenarioCoverage` | with `acceptanceMode: reviewed`: every `#### Scenario:` of a change's spec deltas (not under REMOVED) must be named literally in its acceptance test files, otherwise the start is refused | `true` |
| `notifyScript` | PowerShell script that sends a push notification (see Notifications below); the start is refused if it does not exist | off |
| `notifyProjectName` | project name in the notifications | project folder name |
| `notifyStopPriority` | priority of the stop/crash message (Pushover: `1` high, `2` repeats until acknowledged) | 1 |
| `notifyTimeoutSeconds` | time limit of one notification | 30 |
| `minFreeMemoryGB` | warn at the start when less physical memory is available (with the 5 biggest processes, local only); also the limit for "a test timeout means out of memory"; `0` = off | 8 |
| `maxCommitPercent` | warn when the commit charge (memory promised to programs, RAM + page file) is above this percent of its limit – Windows refuses memory when the limit is reached, even with RAM free; checked at the start, before every run and before every test command; `0` = off | 85 |
| `criticalFreeMemoryGB` | critical level of available memory: below it the runner waits up to `memoryWaitMinutes` for memory and then stops (`STOPPED`); `0` = off | 3 |
| `criticalCommitPercent` | critical level of the commit charge in percent of its limit, same handling; `0` = off | 95 |
| `memoryWaitMinutes` | how long to wait at a critical level (measured every 30 s) | 10 |
| `memoryCleanupCommands` | commands that free memory, run by the runner as the first step of memory recovery, e.g. `["gradlew --stop"]`, `["mvnd --stop"]`, `["dotnet build-server shutdown"]`; at the low level at most once per 10 minutes, always at the critical level and before a retry after out of memory; output in `runs/<time>/cleanup.txt`; a failing command is only a note, one that leaves the working tree dirty stops the change | `[]` |
| `keepProcesses` | process names (wildcards, `.exe` optional) that memory recovery never stops even when a run started them, e.g. `["qemu-system-*", "emulator*", "adb"]` | `[]` |
| `preventSleep` | keep Windows awake during the run (`SetThreadExecutionState`); the screen may still turn off | `true` |
| `memoryErrorPatterns` | substrings (case-insensitive) that mark a red test run, the runner's or the worker's, as out of memory; `[]` = off | `java.lang.OutOfMemoryError`, `GC overhead limit exceeded`, Gradle/Kotlin daemon died, JVM could not reserve memory |

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

- Scenario coverage (`scenarioCoverage`, on by default): before the start, the script checks that the name of every scenario appears in the acceptance test files of its change (e.g. `test('Scenario: Valid password', ...)`) and names the missing ones. It checks that a test exists, not that it is good; that is what your review is for.
- The agent may not edit `acceptance/` (deny rules), and the script checks after every run that no commit touched it. A change there stops the loop (FAILED-CHECK).
- The script runs them when the last task group is done (red: repair run with the output), after archiving, and the tests of all archived changes before the start and after every archive.
- If the agent thinks an acceptance test is wrong, it stops with `BLOCKED.md`; you decide.
- `testCommand` must not pick them up, otherwise the tests of changes not yet implemented make the start red. With `node --test`, which finds `**/*.test.js`, name them `*.accept.js`. Run them directly (`node --test ...`), not through a `package.json` script: the agent can edit `package.json`, but not `openspec/auto-mode.json`.
- What they cannot prevent: an implementation fitted to the test inputs, or changes to helper files the tests import from outside `acceptance/`. Keep acceptance tests self-contained and use more than one example per scenario.

### Notifications (optional, `notifyScript`)

The script can tell your phone how the run goes, so you do not have to watch `openspec/changes/`. Set `notifyScript` to a PowerShell script of your own that sends the message (Pushover, Telegram, e-mail…). The script calls it:

| When | Message (example) | Priority |
|---|---|---|
| start | `▶ auto-mode started: 3 changes, first 01-login` | 0 |
| change done (archived, script's tests green) | `✅ 01-login done (1/3) · 2 runs · 0.40 USD · 12 min` | 0 |
| change NONCRITICAL | `⚠ 02-export done with a noncritical issue (2/3); fix-02-export next` | 0 |
| fix change done | `✅ fix-02-export fixed 02-export · …` | 0 |
| run finished | `🏁 auto-mode finished: 3/3 done · 1.10 USD · 48 min; report: …` | 1 |
| run stopped (BLOCKED, FAILED-CHECK, STOPPED) or crashed | `🛑 auto-mode stopped at 02-export: <reason> · …` | `notifyStopPriority` |

The title of every message is the project name (`notifyProjectName`, default: the project folder name), so runs in several projects at the same time can be told apart. Silence after the start message without a finished/stopped message means it is still working.

Your script must accept `-Message <string>` and `-Priority <int>`, optionally `-Title <string>` (without it, the project name is put in front of the message as `[name]`), and exit with a non-zero code when sending failed. It runs in a separate process with a timeout (`notifyTimeoutSeconds`); keys and tokens stay in your script, the auto-mode script never sees them. A failed send is only a warning in the report; after 3 failures in a row the script stops trying for the rest of the run. Only change names, counts, cost and time are sent, never code or test output. For Pushover, such a script reads the API token and user key from a `.env` file next to it and posts `token`, `user`, `title`, `message` and `priority` to `https://api.pushover.net/1/messages.json` ([Pushover API](https://pushover.net/api)).

`notifyScript` is an absolute path on your PC (relative = from the project root), so it lives in `openspec/auto-mode.json` of each project that should notify. The agent cannot edit that file.

## Usage

1. Prepare the changes interactively (`/opsx:propose`) and name them in order: `01-login`, `02-profile`, … It does not have to be the whole project, a batch is enough; add more changes later and run again.
2. Commit them; the working tree must be clean.
3. Run it (start with `-DryRun` if you like). At start it checks that every numbered change has a complete proposal: all artifacts, at least one task in `tasks.md`, and `openspec validate` passes. If not, nothing runs and it lists what is missing where.

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\openspec-auto-mode\openspec-auto.ps1   # in the project root
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -DryRun                      # checks and plan only
powershell -ExecutionPolicy Bypass -File ...openspec-auto.ps1 -SetupAcceptanceSchema       # acceptance artifact in the OpenSpec workflow
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -Project C:\other\project
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -Background                  # own window, outside the caller's process tree
```

### Background runs and memory

- **`-Background`** (used by the skill): the runner starts a copy of itself in a new minimized window and exits, so the copy has no living parent. Ending or closing the program that started it (Claude Code, the terminal) does not end the run. The launcher waits up to ~20 s for the copy to report `running`, prints its PID and the paths of `running.json`, `console.txt` and `last-run.json`, and exits 2 with the reason when the start failed (also notification `🛑 auto-mode could not start: …`). At every start the runner logs whether it is inside a job object and warns if that job kills its processes on close.
- **Run state:** `.openspec-auto/running.json` while a run goes (PID and start time, current change, run and child process), `.openspec-auto/last-run.json` at the end (`finished` / `stopped` / `crashed` / `failed-start`), console output in `runs/<time>/console.txt`. A second start in the same project is refused while the first one lives.
- **Child processes:** everything the runner starts (worker, tests, notify script) is in a job object with kill-on-close, so stopping the runner (`Stop-Process`, closing its window) also stops the worker. Daemons started inside the run (Gradle, Kotlin, adb, an emulator) end with it.
- **Interrupted run:** the next start sees a `running.json` whose process is gone, says so, and if the tree is dirty, stashes the leftovers (`git stash push --include-untracked`, message `openspec-auto: leftovers of interrupted run …`), lists the files, and redoes the unfinished group. A dirty tree without an interrupted run is still an error. The runner never drops a stash; the report lists the remaining `openspec-auto:` stashes.
- **Memory checks and log:** before every run and every test command the runner measures available memory and the commit charge and warns below `minFreeMemoryGB` / above `maxCommitPercent` (warning only, the run goes on). The report has a line `Memory: lowest … available, highest commit … %` and, when it was low, a warning with the number of low checks. During the run `memory-log.ps1` writes one line per minute to `runs/<time>/memory.csv` (time, available, commit, limit, percent, the 5 biggest processes; local only, never in notifications); it ends with the runner.
- **Processes left by runs:** every worker run and test command runs in its own job object nested in the runner's job, so the runner sees what a run left running (build daemons, dev servers, an emulator the agent started), also detached processes. They are listed (`left running after run 1 of 01-a: …`, report section `Processes left by runs`). When memory is low before a run or a test command, the runner stops them, except `keepProcesses`, and measures again. Processes that were running before the batch started are never touched.
- **Memory recovery:** two levels. *Low* (below `minFreeMemoryGB` / above `maxCommitPercent`): run `memoryCleanupCommands` (at most every 10 minutes), stop leftover processes, then go on. *Critical* (below `criticalFreeMemoryGB` / above `criticalCommitPercent`): the same, then wait up to `memoryWaitMinutes`; if memory comes back the run goes on, otherwise the change stops with `STOPPED` (`memory stayed critical for … min …`) before the run or the tests start, and the next start continues. After an out-of-memory error (worker `LOW-MEMORY` or tests) the runner frees memory and repeats the same run or tests **once per change** (tests log `….retry.txt`); a second error stops as described below.
- **Out of memory:** a red test run counts as out of memory when its output matches `memoryErrorPatterns`, or it timed out while less than `minFreeMemoryGB` was available. The worker ends with `AUTO-MODE-RESULT: LOW-MEMORY` when its own build or tests hit a memory error, without committing. Either way: no repair run, no `fix-` change, the change ends as `STOPPED` (`… ran out of memory …`), worker leftovers are stashed, and the run can simply be started again. The worker may not change memory or JVM settings unless a task asks for it.
- Heavy projects (Gradle, Android): see GUIDE section 5.7.

## Results

| Result | What happens |
|---|---|
| SUCCESS | change implemented and archived, the script's own test run passes → next change |
| NONCRITICAL | archived + a `fix-NN-name` change describing the bug is created. Tests green (bug not visible to tests): the fix waits for you → next change. Tests red: the script processes the fix right away on the same branch (at most `maxRunsPerFix` runs, done = tests green) → next change, or **stop** if the fix does not pass |
| BLOCKED | architectural problem, `openspec/changes/NN-name/BLOCKED.md`, not archived → **stop** |
| FAILED-CHECK | a script check failed (uncommitted changes, invalid specs, push attempt, crash, timeout, no progress, tests fail after archiving) → **stop**; the stop reason names the first problem (`run 3 of 02-x: agent left branch …`) |
| STOPPED | a limit was reached (`maxRunsPerChange`, `maxRunsPerFix`, a group still red after `maxGroupRepairs` repair runs), the tests or the worker ran out of memory, or a limit stop without progress / twice in a row → **stop** |

**Limit stops:** a run ended by `maxTurns` or `maxBudgetUsdPerRun` (Claude Code subtype `error_max_turns` / `error_max_budget_usd`) is not a FAILED-CHECK. All other checks still apply (branch, push, validation, frozen acceptance tests). If tasks were ticked, the loop continues with a fresh run (group tests first when a group was completed); without progress the change ends STOPPED (`… without finishing a task; split it in tasks.md or raise maxTurns`); a second limit stop in a row also ends STOPPED. Uncommitted work is stashed and written to `.openspec-auto/leftovers/<change>-runNN.patch`; the next run (also after a restart) gets a hint to read it and use what is correct. After SUCCESS / NONCRITICAL the runner drops these stashes (only limit-stop stashes of that change whose patch exists). `timeoutMinutes` is not a limit stop.

The notes column shows the test result of every task group, e.g. `groups: 1 green, 2 red->green (1 repair)`.

Report: `.openspec-auto/auto-mode-report.md`, logs of every run: `.openspec-auto/runs/<time>/`. The folder is listed in `.git/info/exclude`, so it never gets into the repository.

Nothing is pushed or merged. You review and merge the `auto/NN-…` branches yourself.

## After a stop

Apart from `running.json` / `last-run.json` (section above), the script keeps no state of its own; re-running is the same command.

- **Interrupted or out of memory:** just run again; leftovers are stashed automatically. Look at them with `git stash show -p stash@{0}`, drop them with `git stash drop stash@{0}`.
- **`permission denied: <command>`** in a run log: the agent was not allowed to run a command the build or tests need (e.g. `node tools/gen.js`); add it to `allowedCommands`.

- **BLOCKED:** stay on `auto/NN-name`, resolve the problem (e.g. `/opsx:update NN-name`, install a package, edit `design.md`), delete `BLOCKED.md`, commit, run again. While `BLOCKED.md` exists, the script refuses to start.
- **FAILED-CHECK:** check the report and the run log, fix the state (commit or revert), run again from the current branch. The tests must be green again before the next start.
- **Interrupted fix:** if a `fix-NN-name` run was interrupted (crash, timeout), run again from `auto/NN-name`; the script resumes the fix even though the tests are still red.
- **`fix-…` changes waiting for you** (tests were green, `fixMode: stop`, or written by hand) are not processed by the loop. Implement them interactively (`/opsx:apply fix-NN-name`), or rename them to a numbered change.

## Cost

Every run is a full Claude Code session on your account: with a Claude subscription it counts toward your plan's usage limits, with an API key it is billed. The cost shown in the report comes from Claude Code itself. Measured on a small Node project with `sonnet`: about USD 0.15–0.20 per change in one pass (`groupTesting: false`), about USD 0.38 for a change with two task groups (three runs). Set a cap with `maxBudgetUsdPerRun`. The tests in `tests/` use a fake agent and make no API calls.


### Cost dashboard

`dashboard.ps1` collects the cost of every project into one local page, split into **auto-mode** (runner runs), **spec preparation** (interactive sessions that used OpenSpec propose / explore / update / sync), **other interactive work** and **mixed** sessions.

- Sources: `<project>/.openspec-auto/runs/*/*.runNN.out.json` (cost, tokens per model, turns, subtype, unit from the prompt, change result from the report) and the Claude Code transcripts `~/.claude/projects/*/*.jsonl`: per Claude Code process that worked on a session the last `cost-state` record; the session cost is their sum. A session without such a record (crashed, still open) has an unknown cost. Subagent transcripts are part of their session.
- History: `%USERPROFILE%\.openspec-auto\history\runs.jsonl` and `sessions.jsonl`, one record per run / session keyed by project + stamp + change + run or session id; a re-import updates records, records of deleted projects and transcripts stay. Only numbers and names (no prompts, code or conversation text). Raise `cleanupPeriodDays` in `~/.claude/settings.json` (e.g. 90) so transcripts live long enough to be imported.
- Page: `%USERPROFILE%\.openspec-auto\dashboard.html`, self-contained (data embedded, no server): totals per category, cost per week, projects (click for changes, runs and sessions), cost by model, token shares, the 10 most expensive runs and sessions.
- Kept current automatically: the runner imports its project at the end of every start; `install.ps1` adds a `SessionEnd` hook (`dashboard.ps1 -Hook`, returns at once and imports the session in a hidden process 20 s later; errors go to `history\dashboard-errors.log`) and an "OpenSpec dashboard" shortcut on the desktop and in the Start menu. `install.ps1 -NoDashboard` removes hook and shortcuts. In Claude Code: `/openspec-auto dashboard` or "koľko to stálo".
- Categories: the skill list for spec preparation can be changed in `%USERPROFILE%\.openspec-auto\dashboard-config.json` (`{ "specSkills": [...] }`).
- Costs are list-price values computed by Claude Code; with a subscription they show the value of the usage, not money paid.

## Safety

- The agent runs in `dontAsk` mode: it may only do what is on the allowlist (file tools, `openspec`, local git without branch operations, `testCommand` and `allowedCommands`). Skills are denied: global ones such as OpenSpec's `verify` are for interactive use only.
- Push is blocked by three layers: deny rules, a `pre-push` hook active when `OPENSPEC_AUTO_MODE=1`, and a check of remote refs after every run.
- The agent must not modify `.git/`, `.claude/`, `.openspec-auto/`, `openspec/auto-mode.json` or, with `acceptanceMode`, the acceptance folder (also checked with `git diff` after every run).
- `claude -p` skips the folder trust dialog. Only run it in projects you trust.

## Files

| File | Purpose |
|---|---|
| `openspec-auto.ps1` | control script (loop, checks, report) |
| `memory-log.ps1` | memory log of a run (`memory.csv`), started by the runner |
| `worker-prompt.md` | instructions for the agent of a single run |
| `install.ps1` | installs the `/openspec-auto` skill for the current user, the dashboard hook and shortcuts |
| `dashboard.ps1`, `dashboard-template.html` | cost dashboard: import into the central history, local HTML page |
| `claude-skill/openspec-auto/SKILL.md` | skill source (`install.ps1` fills in the runner path) |
| `templates/auto-mode.json` | project configuration template |
| `tests/run-tests.ps1`, `tests/fake-claude.ps1` | tests of the loop logic with a fake agent (no API calls) |
| `tests/dashboard-tests.ps1` | tests of the dashboard import with synthetic data |
| `GUIDE.md` | step-by-step guide |
| `docs/hardening-plan.md` | design notes: why the script verifies the agent, decisions, and the roadmap |
| `docs/memory-pressure-plan.md` | design notes: background runs, interrupted runs, out of memory |
| `docs/notify-plan.md` | design notes: notifications |
| `docs/memory-recovery-plan.md`, `docs/limit-continue-plan.md`, `docs/dashboard-plan.md` | plans: memory recovery for night runs, continuing after limit stops, cost dashboard |

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

## License

[MIT](LICENSE)
