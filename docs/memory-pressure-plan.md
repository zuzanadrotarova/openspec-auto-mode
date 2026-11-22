# Robust runs under memory pressure: spec

Status: reviewed twice (risks, open questions and second review settled 2026-11-22); steps 1
and 2 implemented 2026-11-22 (tests T30–T39), steps 3–5 open.
Date: 2026-11-22

## 1. Problem (trial of 2026-11-21)

A run on a mobile app project (Android emulator, Gradle builds) was
killed twice in the middle of a change (in two different changes):

- The killer was **Claude Code itself**: when free memory drops (here a few GB) it kills
  background shells of an idle session. The skill starts the runner as such a background shell,
  so the whole runner and its worker died. The console output ends with `[killed]`; the last
  `runNN.prompt.txt` has no `out.json`.
- **No 🛑 notification** arrived: a hard kill skips `catch`/`finally`, so the user saw only silence.
- Memory was taken by the emulator, the Gradle and Kotlin daemons (`java`), the IDE and a browser.
  After closing them the following changes passed.
- Both times uncommitted files of the unfinished group were left in the working tree (9 files,
  then 1). The next start refused (`working tree is not clean`) until they were discarded by hand.
- Separately, change 03 was BLOCKED because the worker was denied `node tools/…` (not in
  `allowedCommands`). That is a setup problem, not a memory problem (section 10).

Claude Code's kill message names `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1`. That only switches
the reaper off for the whole session and does not help when Windows itself runs out of memory;
section 4 removes the dependency instead.

## 2. Goal

1. A run is never killed because Claude Code is short of memory.
2. A run that dies anyway (power cut, user closes the window, Windows kills it) leaves a state the
   next start understands: no manual cleanup, nothing lost, no worker left running.
3. Running out of memory is recognised as such, by the runner and by the worker, and no paid
   repair run is spent on it.
4. The user is warned before the start when memory is already low, and the docs say how to make
   heavy projects (Gradle, emulators) lighter.

## 3. Principles

- **Never delete the user's or agent's work.** Leftovers are stashed, never reset or cleaned.
- **Warn, do not block, on memory.** Free memory is a hint; the tests decide.
- **No process outlives the runner.** Every child (worker, tests) ends when the runner ends.
- **The skill stays the only interface.** The user still says `/openspec-auto run` and `report`.
- **Everything is visible in files** (`.openspec-auto/`), so the skill and the user can see the
  state without the runner's console.
- **Only numbers leave the PC.** Notifications carry counts and GB, never process names.

## 4. A – runner runs outside Claude Code

### 4.1 Launch

New switch `-Background` in `openspec-auto.ps1`. With it the runner does not run the loop itself:

1. It starts a new, independent copy of itself (same `-Project`, `-ClaudeCommand`, without
   `-Background`) in a **minimized window**, then prints the PID and the paths of the console log
   and the status file, and exits 0.
2. The copy is created through WMI (`Invoke-CimMethod Win32_Process Create` with
   `ShowWindow = 7`, minimized without focus). Its parent is the WMI service, not the Claude Code
   shell, and it is outside the shell's job object, so neither the reaper nor closing Claude Code
   kills it. `Start-Process` is not enough on its own: a process started from a shell inside a job
   stays in that job. Step 3 checks this with a real kill (section 13).
3. **Environment.** A WMI process gets the user's environment from the registry, not the shell's:
   `JAVA_HOME`, a `PATH` extended in the session, `CLAUDE_*` and similar would be missing. The
   launcher therefore passes its whole current environment (`Win32_ProcessStartup
   .EnvironmentVariables`) and the project root as `CurrentDirectory`. The copy then behaves like a
   run started directly; test 13 checks that it finds `claude`, `openspec` and the test command.
   If `EnvironmentVariables` turns out not to be applied reliably (test 13 shows it), the fallback
   is an environment file: the launcher writes the environment to
   `.openspec-auto/launch-env.<launcher pid>.bin`, encrypted with DPAPI for the current user
   (`ConvertFrom-SecureString`, readable only by this Windows account on this PC), and passes its
   path to the copy as a parameter (`-EnvFile <path>`; the copy has a different PID, so it cannot
   guess the name). The copy reads it as the very first step, deletes it at once (also when reading fails), and never writes any value
   to a log or the console. The file can hold secrets (e.g. `ANTHROPIC_API_KEY`, if set); normally
   `claude` signs in through `~/.claude` and no key is in the environment.
4. **Fallback.** If the WMI call fails (policy, antivirus rule "block process creations from WMI"),
   the launcher uses `Start-Process` with the same environment and prints a warning that this run is
   not protected from Claude Code's memory reaper.
5. Start checks (including the baseline tests) run in the copy, as today. The skill runs `check`
   before `run` anyway, so an error is normally seen before the launch. An error that appears only
   in the copy goes to the console log, to `last-run.json` (`state: "failed-start"`) and, if
   notifications are on, to a notification E8 `🛑 auto-mode could not start: <short reason>`
   (priority `notifyStopPriority`).

### 4.2 Child processes (Job object)

Today a child process on Windows does not end when the runner ends. After `Stop-Process` on the
runner (or a crash of the runner alone), the worker `claude` could keep editing and committing while
the next run starts.

- At the start of the loop the runner creates a Windows **Job object** with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (P/Invoke through `Add-Type`).
- `Invoke-Process` assigns every process it starts (worker, `cmd.exe` running tests, acceptance
  tests, notify script) to that job right after `Process.Start`. Their own children are in the job
  automatically.
- When the runner process ends in any way (normal end, crash, `Stop-Process`, closed window),
  Windows closes the job handle and kills everything in it.
- `running.json` also holds the PID of the current child (`childPid`, `childStart`), so a start
  check sees a still living worker even in the rare case that the job did not catch it (section 5.3).
- The `taskkill /T` on timeout stays as it is.
- The job also ends daemons started by the tests or the worker: Gradle daemon, Kotlin daemon, the
  adb server, and an emulator the worker started itself. Good for memory; the next build / adb start
  takes a few seconds longer, and Android Studio loses its adb connection for a moment at the end of
  a run. GUIDE: start the emulator before the run, outside auto-mode (section 10).

### 4.3 Files

| File | Written | Content |
|---|---|---|
| `.openspec-auto/running.json` | at start, updated when a change / run / child starts, deleted at the normal end | `pid`, `processStart` (start time, against PID reuse), `childPid`, `childStart`, `runDir`, `startedAt`, `change`, `run`, `consoleLog` |
| `.openspec-auto/last-run.json` | at the end (normal, stop, crash, failed start) | `exitCode`, `state` (`finished` / `stopped` / `crashed` / `failed-start`), `endedAt`, `runDir` |
| `.openspec-auto/runs/<stamp>/console.txt` | whole run | console output (`Start-Transcript`) |

`console.txt` contains what the runner prints. That is enough: the runner never lets a program write
to the console directly; the output of `claude`, the tests and `git` is always captured
(`Invoke-Process`, `Invoke-Exec` with `2>&1`) and stays in the per-run logs (`runNN.out.json`,
`*.tests.txt`). Together with `running.json` this tells which change and run were going when a run
died.

A run is **running** when `running.json` exists and its `pid` lives with the same `processStart`.
It was **interrupted** when `running.json` exists but the process is gone.

### 4.4 Skill

- `run`: after `check`, start the runner with `-Background` (foreground, returns at once). After
  ~10 seconds read `running.json` / `last-run.json`: if the start failed, explain it right away.
  Otherwise start a small waiter in the background (`Wait-Process -Id <pid>`,
  `run_in_background: true`), so Claude Code is still told when the run ends. The waiter uses almost
  no memory; if the reaper kills it anyway, the runner keeps running, only that notice is missing.
- Progress ("how is it going?"): read `running.json` and the last ~30 lines of `console.txt`.
- `report`: as today; additionally, if `running.json` names a living process, say it is still
  running; if it names a dead one, say the run was interrupted (and that the next start stashes the
  leftovers, section 5).
- To stop a run: close its window, or let the skill run `Stop-Process -Id <pid>`. Both end the
  worker too (section 4.2). The next start treats it as interrupted.

## 5. Interrupted runs and stash

### 5.1 Detection

At the start, before the clean-tree check: if `running.json` exists and its process is gone, the
previous run was interrupted. The runner says so (`previous run <stamp> was interrupted during
<change> run <n>`) and adds it to the warnings.

### 5.2 Stash

If the previous run was interrupted **and** the working tree is dirty:

1. The runner prints the list of files (`git status --porcelain`) to the console and the report.
2. ```
   git stash push --include-untracked -m "openspec-auto: leftovers of interrupted run <stamp> (<change> run <n>)"
   ```
   Without a pathspec (found in step 1): `-- . ":!.openspec-auto"` makes `git stash` save the
   stash and then fail halfway, leaving the files staged, because the pathspec names an ignored
   folder. Success is judged by a new `refs/stash` entry and a clean tree, not by the exit code.

- Automatic, without asking (decision 2, section 15): a run without supervision has nobody to ask,
  and nothing is lost.
- Only in this case (and right after a LOW-MEMORY result, section 7). A dirty tree without an
  interrupted run is still an error (it is the user's work), exactly as now.
- Ignored files are not touched (no `--all`).
- `.openspec-auto/` is already in `.git/info/exclude` (written at every start before the clean-tree
  check), so it is never part of `git status` or a stash. Safety net for a project whose
  `.gitignore` re-includes it (`.gitignore` wins over `info/exclude`): the clean-tree check uses
  the pathspec `:!.openspec-auto`, and the stash is refused (exit 2) when
  `git check-ignore .openspec-auto/running.json` says the folder is not ignored.
- The stash is made on whatever branch is checked out (normally `auto/<change>`); the message and
  the report name that branch. The run then resumes as today and redoes the unfinished group.
- The message goes into the console, the report warnings and the E1 notification
  (`▶ auto-mode started … · leftovers of the interrupted run stashed (stash@{0}, 9 files)`).
- GUIDE explains how to look at it (`git stash show -p stash@{0}`) and drop it (`git stash drop`).
  The runner never drops a stash. The report lists all `openspec-auto:` stashes that still exist.
- If `git stash` fails, it is a start error (exit 2) with the git output; nothing else is done.

`running.json` is then replaced by the new run's file.

### 5.3 Double start

- `running.json` is created with `FileMode.CreateNew`, so of two starts at the same moment only one
  succeeds; the other gets exit 2. A stale file of an interrupted run is renamed away first
  (section 5.1), then created anew.
- If `running.json` names a living runner (same `processStart`), or a living child
  (`childPid` with the same `childStart`), the start fails with exit 2:
  `auto-mode is already running in this project (PID n, since hh:mm)` or
  `a worker of the previous run is still running (PID n); end it first`.
- With `-DryRun` this is a warning only (a check during a run must not lie, but must not fail).

## 6. A1 – recognise out-of-memory in the runner's tests

After every test run of the runner (baseline, group test, final test gate) the runner checks for
memory problems. Default list (key `memoryErrorPatterns`, plain substrings, case-insensitive):

- `java.lang.OutOfMemoryError` (also covers the Kotlin daemon)
- `GC overhead limit exceeded`
- `Gradle build daemon disappeared unexpectedly`
- `The daemon has terminated unexpectedly`
- `There is insufficient memory for the Java Runtime Environment`
- `Could not reserve enough space`

A test run counts as **out of memory** when it is red and either

- its output contains a pattern, or
- it hit `testTimeoutMinutes` **and** available memory at that moment is below `minFreeMemoryGB`
  (heavy swapping makes tests slow). A timeout with enough memory stays a normal red timeout, so a
  really hanging test is not hidden.
  Available memory is measured in `Invoke-Process` **at the moment of the timeout, before
  `taskkill`** (afterwards the killed processes have freed it and the rule could never fire), and
  returned in its result (`AvailableMBAtTimeout`).

Then:

- no repair run, no `fix-…` change, no NONCRITICAL;
- the change ends as `STOPPED` with the reason `tests ran out of memory (<matched line> | timeout
  with x.x GB available); close other programs and run again`; the branch and commits stay;
- notification E6 `🛑 auto-mode stopped at 06-x: low memory (x.x GB available)`;
- baseline: exit 2 with the same explanation instead of `baseline tests fail`.

Green tests with a matching line (e.g. a test of OOM handling) count as green. An empty list
switches the pattern part off; the timeout part follows `minFreeMemoryGB` (`0` = off).

## 7. A1 – out-of-memory inside a worker run

The runner does not see the output of the builds and tests the worker runs itself (`out.json` holds
only the worker's final message). So the worker gets the rule.

`worker-prompt.md`, new rule:

- If a build or test command fails with one of the memory errors (the runner puts the list
  `memoryErrorPatterns` into the prompt), do not try to fix code or tests and **do not commit**:
  the tests could not run, so nobody knows whether the state is green. Leave the files as they are
  and end with `AUTO-MODE-RESULT: LOW-MEMORY` and the matched line.
- Never change memory or JVM settings (`org.gradle.jvmargs`, `-Xmx`, `kotlin.daemon.jvmargs`,
  `gradle.properties` memory keys, emulator settings) unless a task of the change asks for it.

Runner:

- New result `LOW-MEMORY`: no `BLOCKED.md`, no fix change. The change ends as `STOPPED` with
  `worker ran out of memory: <line>; available now x.x GB`, notification E6 as in section 6.
- **The runner stashes the leftovers right away** with the same function and rules as after an
  interrupted run (section 5.2: file list first, pathspec, message `openspec-auto: leftovers of
  LOW-MEMORY in <change> run <n>`); report and E6 say so. The tree is then at the last commit, so
  the baseline of the next start does not run on a half-done, possibly red state.
- Not BLOCKED on purpose: BLOCKED means an architectural problem, and `BLOCKED.md` makes the next
  start refuse until the user deletes it by hand. After LOW-MEMORY, `/openspec-auto run` just
  continues from the last commit and redoes the unfinished work.
- Not chosen: running the next baseline on the last commit whose group tests passed. It would mean
  checking out an older commit inside an `auto/…` branch chain; too easy to tangle branches.
- The write check accepts LOW-MEMORY without a new commit and with a dirty tree (the stash follows).
- Remaining gap: commits the worker made earlier in the same run, before the memory error, may be
  red. That is the same as today after a CONTINUE in the middle of a group (risk 37).

## 8. A2 – no sleep during the run

At the start of the loop the runner calls `SetThreadExecutionState(ES_CONTINUOUS |
ES_SYSTEM_REQUIRED)` (P/Invoke through `Add-Type`), and in `finally` `ES_CONTINUOUS` again. The
request belongs to the calling thread; the runner runs the whole loop in its one main thread, so it
holds for the whole run. The screen may still turn off; the PC does not go to sleep. Windows drops
the request when the thread ends, so even a killed run leaves no setting behind. Key
`preventSleep`, default `true`. Closing a laptop lid may still put it to sleep (power settings win).
No watchdog in this plan. The real check with `powercfg /requests` is mandatory (section 13).

## 9. B – memory warning at the start

After the start checks (also in `-DryRun`):

- **available** physical memory from `GlobalMemoryStatusEx` (`ullAvailPhys`, P/Invoke), which
  includes the standby cache Windows can free at once. Not `FreePhysicalMemory` (leaves the cache
  out and would warn all the time) and not the performance counter `\Memory\Available MBytes`
  (its path is localized, so `Get-Counter` fails on a non-English Windows). `ullAvailPhys` is also
  what Node reports as free memory, so it is probably the number Claude Code's reaper looks at
  (not verified). The same function is used everywhere in this plan (sections 6, 7, 9);
- below `minFreeMemoryGB` (default `8`, decision 1; `0` = off) → warning, not an error:
  `only 3.9 GB memory available (minFreeMemoryGB 8); biggest processes: java 3.4 GB (2),
  browser 2.5 GB, qemu-system 2.0 GB, ide 1.5 GB, …`;
- the list shows the biggest processes by working set (top 5, grouped by name, with count); it goes
  only to the console and the local report;
- the E1 notification gets only the number: `⚠ only 3.9 GB memory available`.

In addition, every worker run logs the available memory at its start into `console.txt` (one line),
so a later kill can be explained from the log.

## 10. C – heavy projects (docs only)

GUIDE gets a section "Heavy projects (Gradle, Android, emulators)":

- close Android Studio and browsers you do not need during the run;
- `gradle.properties`: `org.gradle.jvmargs=-Xmx3g` (raise it if the build runs out of memory),
  `kotlin.compiler.execution.strategy=in-process` (no separate Kotlin daemon),
  optionally `org.gradle.daemon=false` (nothing stays in memory between test runs, but every build
  is slower: raise `testTimeoutMinutes`); these are project changes, commit them deliberately;
- give the emulator AVD less RAM, or use tests that do not need it;
- if the changes need the emulator, start it before the run, outside auto-mode (daemons, adb and
  an emulator started inside the run end with it, section 4.2); otherwise close it;
- an interrupted run is resumed by `/openspec-auto run`; leftovers are stashed (section 5).

`afterTestCommand` is **not** implemented (decision 3). GUIDE mentions that `gradlew --stop` frees
memory, with a warning: it stops all daemons of that Gradle version, also those of Android Studio
and of auto-mode runs in other projects, every next build starts slower, and the worker starts the
daemon again anyway.

Change 03 (`node tools/…` denied): the GUIDE appendix gets the row `permission denied: <command>` →
add the command to `allowedCommands`; the skill's `init` also looks for scripts under `tools/`,
`scripts/` and `package.json` scripts the tests or build call.

## 11. Configuration (`openspec/auto-mode.json`)

| Key | Default | Meaning |
|---|---|---|
| `memoryErrorPatterns` | list in section 6 | Substrings that mark a red test run (runner or worker) as out-of-memory. `[]` = off. |
| `preventSleep` | `true` | Keep Windows awake during the run. |
| `minFreeMemoryGB` | `8` | Warn at the start below this much available memory; also the limit for "timeout = out of memory" (section 6). `0` = off. |

Template `templates/auto-mode.json` gets `minFreeMemoryGB: 8`; the other two keep their defaults
without being listed.

## 12. Tests (`tests/run-tests.ps1`)

Available memory, the process list and the WMI launch can be faked through environment variables
read only by the tests (`OSA_TEST_FREE_MB`, `OSA_TEST_PROCESSES`, `OSA_TEST_NO_WMI`), like the fake
claude and notify scripts.

1. `running.json` with a dead PID + dirty tree → file list printed, stash with the message, run
   continues, warning in the report, E1 mentions it; the stash contains the leftover files;
   `running.json` and the logs under `.openspec-auto/` are not in the stash.
2. `running.json` with a dead PID + clean tree → warning only, no stash.
3. Dirty tree without `running.json` → start error as before (no stash).
4. `running.json` with a living runner PID and matching start time → exit 2 "already running";
   with a living `childPid` → exit 2 "worker still running"; with `-DryRun` only a warning.
5. Two starts at the same moment → one runs, the other exits 2 (`CreateNew`).
6. Normal end, stop, crash → `running.json` removed, `last-run.json` with the right state. A crash
   with uncommitted files keeps `running.json` (decision 7), so the next start stashes them.
7. Job object: the fake worker starts a long-sleeping grandchild; `Stop-Process` on the runner →
   the grandchild is gone too.
8. Red group tests with `java.lang.OutOfMemoryError` → STOPPED, no repair run (fake claude called
   once less), E6 says low memory; red without a pattern → repair as before; green with a pattern →
   green.
9. Test timeout with low fake memory → STOPPED low memory; the same timeout with 16000 → normal red
   timeout. The fake value is low only while the test process lives and high after it is killed
   (e.g. `OSA_TEST_FREE_MB_FILE`, a file the fake test writes and deletes), so the test fails if the
   runner measures after `taskkill`.
10. Baseline red with a pattern → exit 2 with the memory message.
11. Fake worker leaves uncommitted files that make the tests red and ends with
    `AUTO-MODE-RESULT: LOW-MEMORY` → STOPPED, no `BLOCKED.md`, no fix change, the files are in a
    stash, the tree is clean; the next start has green baseline tests and continues the change.
    The prompt contains the pattern list.
12. `OSA_TEST_FREE_MB=3000` → warning with the process list in the report; E1 contains the number
    but no process name; `minFreeMemoryGB: 0` → no warning.
13. `-Background` → returns at once with PID; the copy finds `claude` (fake), `openspec` and the
    test command with an environment variable set only in the launching shell, writes
    `running.json` and `console.txt`, finishes the fake run; `last-run.json` shows `finished`.
14. `-Background` with a failing start check → `last-run.json` `failed-start`, notification E8.
15. `OSA_TEST_NO_WMI=1` → fallback launch with the warning.
16. Environment-file fallback (only if it is needed after test 13): the file is encrypted (does not
    contain the test value in plain text), is gone right after the copy starts, also when the copy
    fails to read it, and the test value appears in no log, `console.txt` or report.

## 13. Real checks (not automatable, all mandatory)

- **Kill by Claude Code:** start a short fake run with `-Background` from Claude Code, then end
  the launching shell and close Claude Code → the runner window keeps running and finishes.
- **Closing the window** (all processes of the console get the signal) and **`Stop-Process`** on the
  runner (only the runner is killed): after each, no `claude` / test process of the run is left
  (Task Manager), and the next start reports the interrupted run.
- **Sleep:** during a run, `powercfg /requests` lists the runner under SYSTEM.
- **Trial on a real mobile project** (paid: normal cost of the changes run).

## 14. Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| 1 | Worker keeps running after the runner ends (Windows does not end children with the parent) and works in parallel with the next run | high | Job object with kill-on-close (4.2); `childPid` checked at start (5.3); tests 4, 7; real check (13). |
| 2 | WMI process lacks the shell's environment (`JAVA_HOME`, `PATH`, `CLAUDE_*`) and behaves differently from `check` | high | Pass the whole environment and `CurrentDirectory` (4.1); test 13. |
| 3 | WMI launch blocked by policy / antivirus (it looks like malware behaviour) | medium | Fallback to `Start-Process` with a warning (4.1); test 15; real check shows which one works. |
| 4 | The window is not visible, so it cannot be closed | medium | The skill stops it by PID; real check. |
| 5 | A start error that appears only in the copy is seen late | medium | `last-run.json` `failed-start`, notification E8, skill checks after ~10 s (4.4); test 14. |
| 6 | The waiter is killed by the reaper; Claude Code does not learn that the run ended | low | Notifications and status files stay; `report` reads the files. |
| 7 | Baseline tests run twice (`check` and the copy), minutes more with Gradle | low | Accepted; a skip switch later if it hurts. |
| 8 | Without the reaper, Windows swaps heavily; tests hit the timeout and would trigger paid repairs | medium | Timeout + available memory below `minFreeMemoryGB` = out of memory (6); test 9. |
| 9 | Restart, logoff, power cut still end the run | low | Next start detects the interruption and stashes (5). |
| 10 | `console.txt` misses native output or grows big | low | Native output never goes to the console (4.3); per-run logs hold it. |
| 11 | Stash takes user edits made after the kill | medium | Automatic by decision; file list printed first; nothing is lost; GUIDE: do not edit before the restart. |
| 12 | Stash is made on `auto/…`; popping it on another branch conflicts | low | Message and report name the branch. |
| 13 | Stashes pile up | low | Report lists all `openspec-auto:` stashes. |
| 14 | Big non-ignored files (build outputs) go into the stash | low | File list printed first; GUIDE: add outputs to `.gitignore`. |
| 15 | Two starts at the same moment overwrite `running.json` | low | `FileMode.CreateNew` (5.3); test 5. |
| 16 | `.openspec-auto/` deleted by hand, interruption not detected | low | Accepted: old behaviour (start refuses dirty tree). |
| 17 | Work of the unfinished group goes to the stash and is paid again | low | Accepted; resuming from half-done files would be riskier. |
| 18 | `.openspec-auto/` in the stash / dirty check (a `.gitignore` that re-includes it) | low | Already in `.git/info/exclude`; pathspec `:!.openspec-auto` as safety net (5.2); test 1. |
| 19 | False alarm: memory line in a red output whose real cause is a bug | low | Costs time, not money; patterns configurable. |
| 20 | Out-of-memory looks different from the patterns (silent kill, emulator "device offline") | medium | Timeout rule (6); extend the list from the mobile project's real logs. |
| 21 | Worker "fixes" memory by changing JVM settings or weakening tests | medium | Worker rule: never change memory / JVM settings (7). |
| 22 | Out-of-memory inside a worker run: worker flails or blocks | medium | Worker rule + result `LOW-MEMORY` (7); test 11. |
| 23 | A child starts a grandchild in the moment before it is assigned to the job | low | Tiny window right after `Process.Start`; accepted, `childPid` check as second line. |
| 24 | Wrong memory number (`FreePhysicalMemory` leaves out the standby cache; the performance counter path is localized) gives false warnings or fails | medium | `GlobalMemoryStatusEx` `ullAvailPhys` (9). |
| 25 | Process names leave the PC through Pushover | medium | Notifications carry only the number; list only in the local report (9); test 12. |
| 26 | Memory warnings get ignored | low | Warning only, configurable, `0` = off. |
| 27 | `gradlew --stop` stops daemons of Android Studio and other projects' runs | high | Not implemented; GUIDE warns (10). |
| 28 | `org.gradle.daemon=false` makes tests much slower, timeouts | medium | GUIDE: raise `testTimeoutMinutes`. |
| 29 | `gradle.properties` tips change the project for everybody | low | Tips only; the user decides and commits. |
| 30 | Laptop on battery drains / overheats; lid close may still sleep | medium | `preventSleep: false`. |
| 31 | A hanging runner keeps the PC awake forever | low | Existing worker and test timeouts. |
| 32 | `SetThreadExecutionState` holds only for the calling thread | low | Loop runs in the main thread (8); `powercfg /requests` check mandatory (13). |
| 33 | Closing the window and `Stop-Process` behave differently for children | medium | Job object covers both; real check tests both (13). |
| 34 | Regressions in the 1 238-line runner | medium | Existing tests + section 12, small steps. |
| 35 | An old installed skill with the new runner works the old way (no protection) | low | Tell the user to run `install.ps1` after step 3. |
| 36 | Bugs cause needless paid runs; the trial is paid | low–medium | Steps 1–4 tested with the fake worker (free). |
| 37 | A commit the worker made earlier in a LOW-MEMORY run (or a CONTINUE in the middle of a group) is red, so the next baseline fails | low | Worker rule "try to leave the group green"; LOW-MEMORY itself does not commit (7); baseline red with a memory pattern gives the memory message (6). |
| 38 | The environment-file fallback puts secrets on disk | medium | Only if needed; DPAPI-encrypted for the user, deleted at once, never logged (4.1); test 16. |
| 39 | The job ends daemons, adb and an emulator started inside the run; Android Studio loses adb for a moment | low | Intended for memory; GUIDE: start the emulator before the run (10). |
| 40 | Timeout rule measured after the kill would never fire | medium | Measure before `taskkill` (6); test 9 built to catch the wrong order. |

## 15. Decisions (2026-11-22)

1. `minFreeMemoryGB`: 8 GB (Claude Code killed at ~4 GB, so the margin fits).
2. Stash: automatic, with the file list printed first.
3. `afterTestCommand`: not implemented; only described in GUIDE with the warning (risk 27).
4. Out-of-memory in a worker run: new result `LOW-MEMORY`, not BLOCKED; the worker does not commit,
   the runner stashes the leftovers right away (section 7).
5. Available memory from `GlobalMemoryStatusEx`, measured before a timeout kill (sections 6, 9).
6. Environment for the WMI copy: `EnvironmentVariables`; DPAPI environment file only as fallback
   (section 4.1).
7. A runner crash (unexpected error) with uncommitted files keeps `running.json`, so the next start
   treats it as interrupted and stashes the leftovers; with a clean tree it is removed (after
   step 1).

## 16. Implementation steps (each needs an explicit ok)

1. `running.json` / `last-run.json`, interrupted-run detection, stash, double-start guard,
   Job object (sections 4.2, 4.3, 5) + tests 1–7.
2. A1 in the runner and the worker, A2, B (sections 6–9) + tests 8–12.
3. `-Background` launch with environment and fallback, and the skill changes (sections 4.1, 4.4)
   + tests 13–15 (16 if the fallback is needed), then the real checks (section 13, without the trial).
4. Docs: GUIDE / README sections, GUIDE appendix rows (section 10).
5. Trial on a real mobile project (paid).
