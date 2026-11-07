# Hardening openspec-auto-mode: discussion and plan

Status: step 1 implemented (not committed yet); `tests/run-tests.ps1` passes (73 checks). Next: try it on a small real project.
Date: 2026-11-07

## 1. Starting point

The review request compared this repo with the "loop + graph" approach to unattended agent work
(Karpathy's autoresearch, the "Loops & Graphs" article, the "Karpathy loop as a graph" prompt card,
Bun's Zig → Rust port). Core idea taken from it: **the verifier is a program the agent cannot
modify; the agent never grades itself.** Evidence ranking: STRONG = tests exit 0 observed by a
program; WEAK = a reviewer agent approves; NOISE = the model says it is done.

The repo already follows most of it (fresh context per run, memory only in files, deterministic
runner that verifies files, run/time/budget limits, no-progress stop, BLOCKED escalation, allowlist,
no push/merge). Design principle to keep: the runner is deterministic and does not trust the agent.

## 2. Verified assumptions

| # | Assumption | Verdict | Evidence |
|---|---|---|---|
| 1 | Runner never runs `testCommand` | **Confirmed** | `openspec-auto.ps1` only checks it is set (:395), adds it to the allowlist (:236) and puts it in the prompt (:275). SUCCESS = all tasks ticked + archived (:511), both controlled by the agent. |
| 2 | Worker tests only at the end; ticking is the model's judgment | **Confirmed** | `worker-prompt.md:40` ("only if it is really done"), `:59` (tests only when all tasks are done) |
| 3 | No notes allowed outside OpenSpec | **Confirmed** | `worker-prompt.md:13` |
| 4 | NONCRITICAL continues, next change branches from it, `fix-…` never processed | **Confirmed** | `:557` continues on NONCRITICAL, `:466` branches from current HEAD, `:92` only `^\d{2,}-` is processed |

Additional facts checked in a scratch repo (OpenSpec 1.13.2):
- A `fix-NN` change with `skip_specs: true`, no `design.md` and no spec deltas validates and
  archives with plain `openspec archive <name> -y`.
- A file `openspec/auto-rules.md` does not disturb `openspec validate --specs` or `openspec list`.

## 3. Evaluation of the four proposals

### 3.1 Runner runs `testCommand` itself — do it, highest priority
- Benefit: ~40 lines turn "the agent says so" into "a program observed it".
- Risks: tests already red before change 01 would be blamed on it (→ baseline test run at start);
  flaky tests give false FAILED-CHECK; tests that write files make the tree dirty; test time doubles.
- **Biggest limit:** the agent can still modify the verifier (edit `scripts.test` in
  `package.json`, delete or weaken a test). Runner-run tests are strong evidence only when the agent
  cannot change them. This is the difference from autoresearch and is addressed in step 3.
- Coupling: after a NONCRITICAL with red tests every later SUCCESS would fail on the old bug, so
  this cannot ship without deciding 3.4.

### 3.2 Tests after each task — weakest as proposed
- The agent observing its own tests is still weak evidence.
- Conflicts with normal task lists (test-first tasks, scaffolding that compiles only after a later
  task): a hard "green after every task" rule pushes the agent to merge tasks or game tests.
- Better unit: see section 4.

### 3.3 Cross-change rules file — yes, but small
- Benefit: lessons are lost between changes today.
- Risk: a rule is an unverified generalization by the model and applies to all future work
  (one wrong rule propagates); the file costs context in every run; overlaps with `design.md`.
- Shape if done: append-only, one line per rule, written only after a verified fix (not when a
  NONCRITICAL is created – the cause is only a guess then), size cap, new rules listed in the report
  for human review. Safer alternative: the agent proposes rules in the report, a human promotes them.
- Not related to verification; separate later step.

### 3.4 NONCRITICAL handling — option (a), conditioned on red tests
- **(a)** process `fix-NN` right after its change, but **only when the runner itself observed
  failing tests**. Then the pass condition is program-evaluable ("tests turn green"). If tests are
  green, the bug is not test-visible, the agent would grade itself, so the fix waits for the human
  as today. A fix that does not pass within 2 runs stops the loop ("the plan is wrong").
- **(b)** not deterministic: which files the next change touches is unknown before it is implemented.
- **(c)** alone solves nothing; kept as a switch (`fixMode: stop`).

## 4. From "tests per task" to logical units and the spec

- **A – task group as the unit.** `tasks.md` already has groups (`## 1. …`, `## 2. …`). One run
  completes at most one group; after it the *runner* runs the tests. Red inside a group is allowed,
  green at the group end is required. On red, the runner sends back only that group with its test
  output and scope (`git diff --name-only` since the group started), max 2 attempts, then stop.
  Cost: more runs (re-orientation tokens); proposals must make every group end in a testable state.
- **B – scenario coverage.** Every `#### Scenario:` in the change's spec deltas must have a test that
  names it, otherwise no SUCCESS. Cheap and deterministic; checks existence, not quality. Optional
  config switch.
- **C – check written before the task (the Karpathy core).** Acceptance tests exist before the
  implementation and the agent cannot change them.
  - C1: written interactively by the human with Claude during propose. Strongest.
  - C2: written by the agent as group 1, then frozen by the runner. Weaker, but written before code.
  - Mechanism: own acceptance test command in `openspec/auto-mode.json` (already protected, `:251`),
    deny Edit/Write on frozen files, runner checks `git diff` since the freeze point is empty.
    A wrong acceptance test → BLOCKED, human decides (gate by cost of undoing).
  - What does not transfer from autoresearch: one scalar metric, one edited file, revert-if-worse.
    Here the result is pass/fail per unit, and "revert" becomes "return the failing unit".
- Not doing: an agent reviewer comparing code with the spec as a gate (WEAK evidence); at most an
  advisory note in the report.

Why C was not first: it needs a change to the safety layers (explicitly the owner's decision), a
heavier propose phase, and it builds on step 1 anyway (the runner must run tests in every variant).

## 5. Decided order

1. **Step 1 (now):** runner runs tests (baseline + gate after archive) + NONCRITICAL option (a).
2. Try it on a small real project: test duration, flakiness, files left by tests.
3. Step 2: task groups as units (A).
4. Step 3: frozen acceptance tests (C1, then C2).
5. Step 4 (optional): scenario coverage (B) and the rules file (3.3).

## 6. Step 1 – detailed plan

### 6.1 New config keys (`openspec/auto-mode.json`, template, README, GUIDE)

| Key | Meaning | Default |
|---|---|---|
| `testTimeoutMinutes` | time limit of one test run by the runner | 20 |
| `fixMode` | `immediate`: after a NONCRITICAL with failing tests, process `fix-NN` right away; `stop`: stop the loop and leave the fix to the human | `immediate` |
| `maxRunsPerFix` | max runs for one `fix-NN` change | 2 |

### 6.2 `openspec-auto.ps1`

1. **`Invoke-Process`** – extract the process start / wait / timeout / kill code from
   `Invoke-Worker` (:299–341) into a helper `Invoke-Process($CommandLine, $TimeoutMinutes, $StdIn)`
   returning ExitCode, TimedOut, Minutes, Stdout, Stderr. `Invoke-Worker` uses it; no behavior
   change. PowerShell 5.1 compatible (same .NET APIs as today).
2. **`Invoke-Tests($Cfg, $LogPath)`** – runs `testCommand` through `Invoke-Process` (cmd.exe /c on
   Windows, /bin/sh -c elsewhere, `OPENSPEC_AUTO_MODE=1`, empty stdin). Writes the full output to
   `$LogPath`. Returns `Passed` (exit 0 and no timeout), `ExitCode`, `TimedOut`, `Tail` (last 40
   lines, each cut to 300 chars), `Dirty` (`git status --porcelain` after the run).
3. **`Read-Config`** – defaults for the three new keys; `fixMode` must be `immediate` or `stop`
   (otherwise start error).
4. **Baseline test run at start** (after the existing start checks pass, also in `-DryRun` so that
   `/openspec-auto check` reports it): log `.openspec-auto/baseline-tests.txt`.
   - red → exit 2: `baseline tests fail (testCommand exit N); auto-mode needs a green start. Output: .openspec-auto/baseline-tests.txt`
   - dirty → exit 2: `testCommand leaves the working tree dirty: <files>; add them to .gitignore`
   - exception (resume of an interrupted fix): red baseline is accepted when an active `fix-X`
     exists, `X` is archived and the current branch is `auto/X`. The fix is then processed first,
     with the baseline output as its evidence.
5. **Queue instead of `foreach`** – `foreach ($c in $numbered)` (:447) becomes a queue of items
   `{ Name; IsFix; Parent; Branch; MaxRuns; Evidence }` iterated by index, so a fix can be inserted
   right after its parent. A fix item uses the parent's branch `auto/NN-name` (already checked out,
   not added to the branch list twice) and `MaxRuns = maxRunsPerFix`.
6. **Gate after archive** – in the evaluation block (:508–521), only when there are no other problems:
   - files say **SUCCESS** (numbered or fix) → `Invoke-Tests` → log `<change>.runNN.tests.txt`.
     Red → problem `tests fail after <change> was archived (testCommand exit N, agent claimed X); output: <log>` → FAILED-CHECK.
     Dirty → problem.
   - files say **NONCRITICAL** (numbered only) → `Invoke-Tests`.
     - green → as today, continue; note `fix-NN: no failing test observed, waits for you`.
     - red + `fixMode=immediate` → outcome NONCRITICAL, insert fix item with `Evidence = Tail`.
     - red + `fixMode=stop` → outcome NONCRITICAL, stop: `tests fail after NONCRITICAL; fix-NN waits for you (fixMode=stop)`.
   - **fix change** specifics: archived with unchecked tasks → problem (there is no fix of a fix);
     an active `fix-fix-…` appears → problem; more than `maxRunsPerFix` runs → STOPPED
     `fix-NN did not pass within N runs; the plan is probably wrong`.
   - Loop break (:557): also break when a stop reason was set.
7. **Worker prompt from the runner** (:271) – new lines:
   ```
   Kind: change | fix (fixes <parent>)
   Runner test evidence (testCommand exit N, last 40 lines):   ← fix only
   <tail>
   ```
8. **BLOCKED start check** (:406) – also covers `fix-X` changes whose parent `X` is archived.
9. **Report** – new column `Tests` (`green`, `red (exit N)`, `-`), a row per processed fix,
   parent note `fixed by fix-NN` / `fix-NN failed`, header line `Baseline tests: green`.

### 6.3 `worker-prompt.md` diffs

```diff
@@ Assignment
-The user message gives you: the change name, the run number, the task budget for this run, and the test command.
+The user message gives you: the change name, its kind (`change` or `fix`), the run number, the task budget for this run, the test command, and for a fix change the failing test output observed by the runner.
@@
-- The only new change you may create is `fix-<change>` (non-critical error, see below).
+- The only new change you may create is `fix-<change>` (non-critical error, see below). When you are working on a fix change, you may not create any new change.
@@ Classify
-   - **SUCCESS**: all tasks done and the test command passes.
+   - **SUCCESS**: all tasks done and the test command passes. The runner runs the test command itself after you archive; archiving with failing tests stops auto-mode.
@@
    When all tasks are done, run the test command. If tests fail and the fix is local and small, fix it (it counts toward the budget). If they still fail, the result is NON-CRITICAL, or CRITICAL if a criterion above applies.
+
+   Never weaken, skip or delete an existing test, and never change the test script or test configuration to make the test command pass. If you believe a test itself is wrong, that is CRITICAL.
@@ Act / NON-CRITICAL
-     2. Write `proposal.md`: what does not work, which test fails (name and short error), where the likely cause is (files), and a reference to the original change `<change>`.
+     2. Write `proposal.md`: what does not work, which test fails (its name exactly as the test command prints it, and the short error), where the likely cause is (files), and a reference to the original change `<change>`. If the tests fail, the runner processes this fix right after `<change>` with a fresh agent.
+
+## Fix changes
+
+When the user message says `Kind: fix`, the runner ran the test command after the original change was archived and it failed; the user message contains that output.
+
+- The only success criterion is that the test command passes. The runner runs it again after you finish and does not trust your result.
+- Scope: the files named in the fix proposal and the failing tests. No refactoring, nothing beyond the fix tasks.
+- The test rule above applies: never change a test to make it pass. A wrong test is CRITICAL.
+- There is no NON-CRITICAL result for a fix change. If the tests still fail after at most 3 attempts per failing test, the result is CRITICAL: `BLOCKED.md` with the failing test, what you tried, and the options.
+- SUCCESS: all fix tasks checked, the test command passes, then `openspec archive <change> -y` and commit.
```

### 6.4 Tests (`tests/run-tests.ps1`, `tests/fake-claude.ps1`)

Setup change: `New-Project` writes `run-tests.cmd`
(`@if exist broken.txt (echo FAIL broken.txt & exit /b 1) else (echo ok)`) and uses it as
`testCommand`; an optional `-Config` parameter overrides `auto-mode.json`. All existing tests stay green.

New fake modes: `success-red` (archive + create `broken.txt`, claim SUCCESS), `noncritical-red`
(noncritical + `broken.txt`), `fixgreen` (delete `broken.txt`, tick, archive), `continue-red`
(tick one task, do not fix). The fake noncritical fix proposal gets 3 tasks.

| Test | Plan | Expected |
|---|---|---|
| T8 SUCCESS with failing tests | `01-a=success-red;02-b=success` | exit 1, `tests fail after 01-a`, 01-a FAILED-CHECK, 02-b not processed, `01-a.run01.tests.txt` exists |
| T9 red baseline | `broken.txt` committed | exit 2, `baseline tests fail`, no `runs/` |
| T9b dirty tests | `testCommand: echo x> junk.out` | exit 2, `leaves the working tree dirty` |
| T10 fix immediate | `01-a=noncritical-red;fix-01-a=fixgreen;02-b=success` | exit 0, fix-01-a and 02-b archived, fix prompt has `Kind: fix` and `FAIL broken.txt`, no `auto/fix-01-a` branch, fix commit on `auto/01-a` |
| T10b fix claims success, still red | `fix-01-a=success` | exit 1, FAILED-CHECK, 02-b not processed |
| T10c fix does not converge | `fix-01-a=continue-red` | exit 1, STOPPED `did not pass within 2 runs` |
| T10d fixMode stop | config `fixMode: stop` | exit 1, fix-01-a active and not processed, 02-b not processed |
| T10e fix blocked + restart | `fix-01-a=blocked`, then restart | exit 1; restart exit 2 `is blocked` |
| T11 resume interrupted fix | `fix-01-a=crash`, then restart with `fix-01-a=fixgreen;02-b=success` | first exit 1; second exit 0, both archived |
| T2 (existing) | noncritical, tests green | still continues; note `no failing test observed` |

The fake agent tests only the runner. Whether the real worker follows the new prompt rules has to
be checked on a real project (step 2 of the order).

### 6.5 Docs
- README: results table (SUCCESS = tests verified by the runner), config keys, after-a-stop section.
- GUIDE: settings table, results table, 5.3 fix changes, start messages (`baseline tests fail`,
  `testCommand leaves the working tree dirty`), note that `check` now runs the tests.
- SKILL.md: `check` explains a red baseline; `report` explains fix rows and the `Tests` column.
- `templates/auto-mode.json`: the three new keys.

### 6.6 Risks of step 1
- Flaky tests → false FAILED-CHECK (no retry in step 1; possible later `testRetries`).
- Longer runs and a slower `check` (tests run in `-DryRun`).
- The gate gives the agent an incentive to weaken tests; step 1 only has a prompt rule against it,
  real protection comes in step 3.
- Behavior change: NONCRITICAL with red tests no longer silently continues to the next change.
- Fix commits live on the parent branch `auto/NN-name`; reviewed together with the change.
- Test output goes into the fix prompt; it is the project's own output, size-limited.

### 6.7 Decisions
- `fixMode` default `immediate`.
- Baseline tests also run in `-DryRun` (`/openspec-auto check`).

### 6.8 Implementation notes
- Claude Code sets `NoDefaultCurrentDirectoryInExePath=1`, which the runner inherits; `cmd.exe`
  then does not find `test.cmd` in the project root by name. A script test command needs `.\test.cmd`
  (documented in README, GUIDE, SKILL). `npm test` and similar are not affected.
- The fix row's result is also noted on the parent row (`fixed by fix-NN` / `fix-NN failed (…)`).
- `null` for one of the three new keys in `auto-mode.json` means its default; existing keys behave
  as before (e.g. `"maxTurns": null` still means no turn limit).
