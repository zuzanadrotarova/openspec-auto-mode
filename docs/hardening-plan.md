# Hardening openspec-auto-mode: discussion and plan

Status: steps 1 and 2 merged into `main` and pushed (8856e64, 1be4dd9), both tried on a real project (sections 6.9, 7.9). Step 3a (frozen acceptance tests written before the start and reviewed by the user, section 8) implemented on branch `step3-acceptance-tests`, fake-agent tests green; tried on the demo project (section 8.5). Step 3b (agent-written acceptance tests) later, probably not needed. Step 3c (acceptance tests as an artifact of the OpenSpec workflow, section 9) implemented, fake-agent tests green, tried on the demo project (section 9.6).
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

### 6.9 Trial on a real project (2026-11-07)
Demo project `openspec-auto-demo` (Node, `node --test`, no packages), changes `01-slugify`,
`02-truncate`, `03-unique-slug` (two task groups each: implementation, tests), model `sonnet`.
- All three SUCCESS in one run each, runner's own test run green after every archive.
- Total USD 0.52, under 2 minutes.
- The agent did not touch the existing test; one test per spec scenario, nothing missing.
- **Finding:** the agent committed all tasks of a change in one commit (`1.1-2.1 …`) although the
  worker prompt asks for a commit per task. Per-task discipline cannot be relied on → step 2 makes
  the runner enforce the unit (task group) and test between units.
- Not exercised by the real agent: NONCRITICAL + immediate fix, SUCCESS with red tests (covered only
  by the fake-agent tests).

## 7. Step 2 – task groups as units (plan)

### 7.1 Idea
A task group in `tasks.md` (`## N. Title` and its `- [ ]` lines) is the unit of work. One run works
on one group only. When a group is complete, the runner runs the tests. Red inside a group is
allowed; red at a group end is sent back as that group only, with the test output and a file scope,
for at most `maxGroupRepairs` runs. Archiving happens in a separate short final run after the runner
has seen the last group green, so a red last group is repaired like any other instead of ending in
FAILED-CHECK.

### 7.2 Config keys
| Key | Meaning | Default |
|---|---|---|
| `groupTesting` | one group per run + runner tests after every group | `true` (open decision) |
| `maxGroupRepairs` | repair runs per group when the runner's tests are red at the group end | 2 |

`tasksPerRun` stays: a group larger than the budget is split over several runs; the runner tests
only at the group end.

### 7.3 Runner (`openspec-auto.ps1`)
1. `Get-TaskGroups($dir)` – parses `## N. Title` headings; tasks before the first heading form an
   implicit group 0. Returns `{ Id; Title; Total; Done; Open[] }`. Same task regex as `Get-TaskCounts`.
2. Run state per change: current group = first group with unchecked tasks; `groupStartHead` (HEAD
   when the group's first run started; on resume = HEAD at start); `repairs` per group.
3. Prompt from the runner (new lines):
   ```
   Task group for this run: 2. Truncate (open tasks: 2.1, 2.2)
   Finish this group only and end with CONTINUE; do not archive in this run.
   ```
   repair run:
   ```
   Repair: group 1 is complete but the runner's tests fail (exit 1).
   Scope: fix only the cause, in these files changed by the group: src/text.js, tests/slugify.test.js
   Runner test evidence (last 40 lines): ...
   ```
   final run:
   ```
   Final run: all task groups are done and the runner's tests are green.
   Do the completion check and archive.
   ```
4. Evaluation after a CONTINUE-like run (change still active, no BLOCKED.md):
   - a group became complete → `Invoke-Tests` → log `<change>.runNN.group<N>.tests.txt`.
     green → progress, next group (or final run); red → next run is a repair run for that group.
   - repair run → `Invoke-Tests`: green → progress; red → `repairs++`; above `maxGroupRepairs` →
     STOPPED `group N still red after M repair runs`.
   - "progress" = more tasks ticked, or a repair run that turned the tests green. Otherwise the
     existing no-progress stop applies.
   - tasks ticked outside the current group → note in the report (not a stop); the test gate still
     runs, only attribution is coarser. (Open decision: note or FAILED-CHECK.)
5. Archive without the final run (agent ignored the rule) → step 1 gate still applies (red =
   FAILED-CHECK, green = SUCCESS with a note).
6. Fix changes (`fix-NN`) keep the step 1 flow (they have one group and a test target already).
7. Report: per change the groups with their test result, e.g. `1 green, 2 red→green (1 repair)`.

### 7.4 `worker-prompt.md` (outline of the diff)
- Assignment: the user message also gives the task group, or a repair or final instruction.
- Implement: work only on the given group; when its tasks are done, run the test command, commit,
  end with `CONTINUE`. The runner tests again and decides.
- Repair: fix only the cause of the failing tests within the given files; no new features, no ticks
  of other tasks; the test rule (never weaken tests) applies; if not fixable → classify as today.
- Act / SUCCESS: archive only in a final run (or when the runner gives no group, i.e. groupTesting off).

### 7.5 Tests (fake agent)
New fake modes: `group` (ticks the open tasks of the group named in the prompt, archives only when
the prompt says Final run), `group-red` (group 1 creates `broken.txt`, repair run removes it),
`group-stuck` (never repairs), existing `success` (ignores groups).
| Test | Expected |
|---|---|
| T12 one group per run | 2 groups → 3 runs (group 1, group 2, final), prompts name the groups, two group test logs |
| T13 repair converges | group 1 red → run 2 is a repair run with evidence and scope `src`; then green → SUCCESS, report `red→green` |
| T14 repair does not converge | STOPPED `group 1 still red after 2 repair runs`, next change not processed |
| T15 agent ignores groups | `success` mode archives in run 1 → SUCCESS with note `ticked tasks outside group 1` |
| T16 groupTesting off | old behavior: one run, no group logs |
Existing T1–T11 must stay green with the default on.

### 7.6 Docs
GUIDE section 2 (proposing): a group should be a logical unit that ends in a testable state and
contains its own tests — "1. Slugify (code + tests)", not "1. Implementation / 2. Tests" (with that
layout the first gate checks nothing new). README/GUIDE config tables, SKILL report wording.

### 7.7 Risks
- Cost and time: each group is a fresh process that re-reads the change. The demo would need 3 runs
  per change instead of 1 (estimate 2–2.5× cost for small changes). Larger changes gain the most.
- The unit only means something if proposals have sensible groups; old "Implementation / Tests"
  layouts gain little.
- Scope after a resume is coarser (files since resume start, not since the group start).

### 7.8 Decisions and implementation notes
- Decisions: `groupTesting` default `true`; ticks outside the current group are a report note, not a stop.
- Start check (exit 2): with `groupTesting`, a change needs `open groups + 1` runs; a too small
  `maxRunsPerChange` is refused before anything runs.
- A repair run does not need to tick tasks; its progress is the runner's test result. Every red
  repair counts; at `maxGroupRepairs` the change is STOPPED.
- Scope of a repair = `git diff --name-only` from the commit where the group started to HEAD.
- Report notes use ASCII (`red->green`) because Windows PowerShell 5.1 reads the BOM-less script as ANSI.
- Known gap: if a change is resumed with all tasks ticked but not archived, there is no extra test
  run before the final run; the step 1 gate after archiving still catches red tests (FAILED-CHECK).
  Tests at start (baseline) cover the common case where the change's branch is checked out.
- Fake-agent tests T12–T17 added; T1–T11 unchanged and green with `groupTesting` on.

### 7.9 Trial on a real project (2026-11-07)
Demo project, change `04-word-tools` with two logical groups (`countWords`, `titleCase`, code +
tests each), model `sonnet`.
- 3 runs as planned: group 1, group 2, final run; runner tests green after each group and after archiving.
- USD 0.38, about 1 minute (a one-pass change cost about USD 0.15–0.20 before step 2).
- The agent kept to one group per run, ticked nothing outside it, did not archive early; commits
  are now per group (`1.1-1.2 …`, `2.1-2.2 …`), so a failure is attributable to one group.
- Existing tests untouched; one test per scenario; `titleCase` reuses `capitalize` as `design.md` says.
- Not exercised by the real agent: the repair run (covered by fake-agent tests T13, T14).

## 8. Step 3 – frozen acceptance tests

### 8.1 Decisions (2026-11-07)
- Split: **3a** = mechanism + C1 (written during propose with Claude, reviewed and approved by the user; what counts is before the code, outside the implementing agent, reviewed, frozen); **3b** = C2
  (the agent writes them in a first run, then they are frozen) later, after a trial of 3a.
- Regression: acceptance tests of already archived changes run at the start (baseline) and after
  every archive.
- 3b: agent-written acceptance tests that are green before the implementation check nothing new →
  STOPPED (not just a note).

### 8.2 Benefits and risks
- Benefit: SUCCESS means tests passed that were written before the code and that the agent could not
  change. Until now only a prompt rule kept the agent from weakening tests.
- Risks: a change to the safety layers (a mistake would stop valid work); heavier propose for the
  human; a wrong acceptance test means BLOCKED; not covered: helper files the tests import from
  outside the acceptance folder, implementations fitted to the test inputs.
- Verified: `node --test` without arguments finds `acceptance/**/*.test.js` (future changes would
  make the baseline red) → acceptance tests use another name (`*.accept.js`) or `testCommand` is
  narrowed. `node --test <dir>/` fails in Node 24; a quoted glob (`"acceptance/x/*.js"`) works.

### 8.3 Design of 3a (as implemented)
- Config: `acceptanceMode` (`off` default | `reviewed`: written before the start with Claude in an interactive session and approved by the user; renamed from `human`, since who types them does not matter), `acceptanceCommand` with `{change}`
  (required when not `off`), `acceptanceDir` (default `acceptance`, plain relative folder).
  `agent` is refused at start until 3b.
- Acceptance tests of a change = files committed under `acceptanceDir/<change>/` (`git ls-files`).
  `reviewed`: a numbered change without them is refused at start (exit 2). Fix changes need none; they
  are checked against their parent's tests.
- Freeze: deny `Edit/Write(./<acceptanceDir>/**)`; after every run the runner checks
  `git diff --name-only <HEAD before the run> HEAD -- <acceptanceDir>/` is empty, otherwise
  FAILED-CHECK `agent changed frozen acceptance tests: …`. Catches `git rm` / `git mv` too, needs
  no stored state (works after a restart); uncommitted changes are caught by the dirty check.
- `Invoke-Tests` takes a list of changes whose acceptance command runs after `testCommand`; all
  must pass; label and evidence come from the first failing command (`red (acceptance 01-a exit 1)`).
- Where: baseline = acceptance of all archived changes; group gate = the change's own acceptance
  only when all its groups are done (red → the usual repair run with the output); after archive
  (SUCCESS / NONCRITICAL / fix) = acceptance of all archived changes, which includes the current one.
- Prompt: the runner names the frozen folder and the acceptance command; the expanded commands are
  on the allowlist. `worker-prompt.md` has a section "Acceptance tests": never touch them, expect
  red until done, no special-casing of test inputs, a wrong acceptance test is CRITICAL.
- Report: `Acceptance tests: reviewed, frozen under acceptance/`, baseline line lists the regression set.
- Skill: new mode `acceptance <change>` writes the tests interactively with the user (one per
  scenario, must fail because code is missing, commit only after the user's ok).

### 8.4 Tests (fake agent)
Fake modes: every mode writes `impl/<change>.txt` when the last task is ticked (the test
acceptance scripts check it); `group-late` (only the repair run writes it), `tamper` (edits the
acceptance script), `tamper-rm` (`git rm`), `success-regress` (removes other changes' `impl/`).

| Test | Expected |
|---|---|
| T18 | acceptance not run after group 1, run after the last group, after the archive of 02-b also 01-a (regression); deny + allow rules; report line |
| T18b | archived change's acceptance red → baseline refused (exit 2) |
| T19 / b / c | change without acceptance tests, command without `{change}`, `acceptanceMode: agent` → exit 2 |
| T20 / b | edited / `git rm`-ed acceptance test → FAILED-CHECK, next change not processed |
| T21 | acceptance red after the last group → repair of that group with the output → SUCCESS in 4 runs |
| T22 | later change breaks an earlier change's acceptance → FAILED-CHECK after its archive |

All 115 checks (T1–T22) green.

### 8.5 Trial on a real project (2026-11-07)
Demo project, change `05-wrap-text` (`wrapText(text, width)`, two groups: greedy wrapping, long
words), acceptance tests `acceptance/05-wrap-text/wrap-text.accept.js` (6 tests, several examples
per scenario plus an invariant over 5 widths) written before the start with Claude and reviewed.
- Reviewing the acceptance tests against a throw-away reference implementation (outside the project)
  found a wrong expectation in one of them (a 4-character line at width 3). It was fixed before the
  commit. Without that check the change would have ended BLOCKED: the review step matters.
- 3 runs as planned (group 1, group 2, final); runner tests green after group 1; after group 2
  `npm test` and the acceptance tests green; after archive both green again.
- The agent did not touch `acceptance/` (no commit there, no permission denials), ran the acceptance
  command itself in the final run, and wrote its own tests in `tests/` as `tasks.md` asks.
- USD 0.46 (0.21 + 0.13 + 0.12), about 1.5 minutes.
- Not exercised by the real agent: a red acceptance test after the last group (repair run), an
  attempt to change a frozen test (covered by fake-agent tests T20, T21).

## 9. Step 3c - acceptance tests as an artifact of the OpenSpec workflow

### 9.1 What OpenSpec already has (checked 2026-11-08, OpenSpec 1.13.2)
- Every requirement needs at least one `#### Scenario:` (WHEN / THEN); the schema says "each scenario
  is a potential test case". So OpenSpec has acceptance criteria, but only as prose.
- No executable acceptance tests: the agent writes tests during apply (the same agent that writes the
  code), nothing protects them, nothing checks that every scenario has a test.
- Custom workflows: `openspec schema fork spec-driven <name>` copies the built-in schema to
  `openspec/schemas/<name>/` (experimental); `openspec status` / `instructions` and `/opsx:propose`
  follow the artifacts of the schema in dependency order.
- Verified: an artifact can only generate files inside the change folder ("generates field must be a
  relative path inside its allowed directory"). Every change records its schema in `.openspec.yaml`;
  `openspec new change` uses the schema of `config.yaml` unless `--schema` is given.

### 9.2 Decisions (2026-11-08)
- Over 3b: the value is the human review before the code; an artifact makes it part of every propose.
  Next: scenario coverage check (step 4 B), using the table in `acceptance.md`.
- New artifact `acceptance` (generates `acceptance.md`: command, files, table scenario -> test),
  between design and tasks: requires specs + design (the tests use the API of design.md), tasks
  requires acceptance. Its instruction has the tests written into `acceptanceDir/<change>/` (outside
  the change folder, as in 3a, so freeze, regression and paths stay unchanged), and explicitly
  authorizes these files despite the planning boundary of `/opsx:propose` ("do not edit project code").
- Optional: without the schema everything works as in 3a; the report notes changes without the artifact.
- Fix changes are created with `--schema spec-driven`: they have no acceptance tests of their own.

### 9.3 Benefits and risks
- Benefit: acceptance tests cannot be forgotten; the start check (all artifacts done) refuses a change
  without `acceptance.md` with no new runner code.
- Risks: custom schemas are experimental (mitigation: setup forks the current built-in schema and
  validates, re-run after an update); `/opsx:propose` may refuse to write files outside `openspec/`
  (checked in the trial; fallback: tests inside the change folder, a bigger runner change); a
  slightly longer propose.

### 9.4 Implementation
- `templates/schema/acceptance-artifact.yaml` (artifact and instruction), `templates/schema/acceptance.md` (template).
- `openspec-auto.ps1 -SetupAcceptanceSchema`: `schema fork spec-driven spec-driven-acceptance --force`, inserts
  the artifact before `tasks`, adds `acceptance` to the requires of `tasks`, copies the template, sets
  `schema:` in `openspec/config.yaml`, `openspec schema validate`; hint if `acceptanceMode` is not set.
  Refuses if the built-in schema has no `tasks` artifact with a block `requires:` list or already has
  an `acceptance` artifact.
- Start check: with `acceptanceMode: reviewed`, changes whose schema has no `acceptance` artifact are
  listed as a warning and a report note (not an error).
- `worker-prompt.md` and the fake agent: `openspec new change fix-<change> --schema spec-driven`.
- SKILL.md (init offers it; the `acceptance` mode also writes `acceptance.md`), README, GUIDE.

### 9.5 Tests (fake agent)
| Test | Expected |
|---|---|
| T23 | setup: artifact before tasks, tasks requires it, template copied, config.yaml selects the schema, schema valid, hint without acceptanceMode; second run gives the same file, artifact once |
| T24 | new change gets the schema; without `acceptance.md` refused at start (`missing artifacts: acceptance`); with it SUCCESS, `acceptance.md` archived; T24b: old schema runs, report note |
| T25 | NONCRITICAL with red tests under the acceptance schema: `fix-01-a` has `schema: spec-driven` and is processed right away |

All 134 checks (T1-T25) green.

### 9.6 Trial on a real project (2026-11-08)
Demo project, branch `auto/06-prep` from `auto/05-wrap-text`: `-SetupAcceptanceSchema` created the
schema and selected it in `openspec/config.yaml` (committed). Change `06-pad-text`
(`padText(text, width, align)`, two groups: left/right, center).
- Proposal: created by Claude following the `openspec-propose` skill step by step (not a fresh
  `/opsx:propose` session). The new change got the schema `spec-driven-acceptance`; the `acceptance`
  artifact came between design and tasks, its instruction led to `acceptance/06-pad-text/pad-text.accept.js`
  (6 tests) plus `acceptance.md`; nothing stopped the write outside `openspec/`. The tests were red
  for the missing function, green on a throw-away reference implementation, and reviewed by the user
  before the commit. `openspec validate --strict` passed.
- Cosmetic: `openspec new change` prints "with schema 'spec-driven'" but writes `spec-driven-acceptance`
  to `.openspec.yaml` (status confirms).
- Before the commit the runner refused the start (working tree not clean), after it `-DryRun` planned
  the change without the "no acceptance artifact" warning.
- Run: SUCCESS, 3 runs (group 1, group 2 + acceptance, final), all tests green, USD 0.47, about
  2 minutes. `acceptance/06-pad-text/` unchanged.
- Still open: whether a fresh `/opsx:propose` session respects the authorization in the artifact
  instruction or refuses because of the skill's planning boundary.

## 10. Step 4 B - scenario coverage

### 10.1 Decisions (2026-11-08)
- Checked at the start, not at SUCCESS: since 3a/3c the acceptance tests exist before the start, so a
  forgotten scenario is found before any paid run, and the check is about the reviewed tests, not
  the agent's own tests.
- Source of truth: the committed files under `acceptanceDir/<change>/` (not the table in
  `acceptance.md`, which is the model's claim). Every `#### Scenario: <name>` of the change's spec
  deltas, except under `## REMOVED Requirements`, must appear there as literal text.
- Config `scenarioCoverage` (bool), default `true`, active only with `acceptanceMode: reviewed`.
  Fix changes and `skip_specs` changes are not checked (no acceptance tests / no scenarios).
- The acceptance artifact instruction and the skill now say that a test name must contain the exact
  scenario name. Projects with the schema re-run `-SetupAcceptanceSchema` to get the new text.

### 10.2 Benefits and risks
- Benefit: free, deterministic, refuses before the agent starts, lists the missing scenarios.
- Limits: existence, not quality (a name in a comment counts); case- and spelling-sensitive.
  Existing projects with differently named tests are stopped at the start (exit 2, no cost, clear
  message, `scenarioCoverage: false`).

### 10.3 Tests (fake agent)
| Test | Expected |
|---|---|
| T26 | spec with two scenarios, test names one: exit 2 naming the other, no agent run |
| T27 | second scenario added to the test: change finishes |
| T28 | scenario under REMOVED not required; `scenarioCoverage: false` accepts an unnamed test; non-boolean value refused |

All 141 checks (T1-T28) green.

### 10.4 Trial on a real project (2026-11-08, free)
Demo project, throw-away branch from `auto/06-pad-text` with a change `07-repeat-text` (two
scenarios, acceptance test naming one): `-DryRun` refused the start with
`scenarios without an acceptance test: "Negative count is rejected"`; after adding the second test
`-DryRun` planned the change, with the acceptance tests of 05 and 06 in the baseline. Branch deleted.
