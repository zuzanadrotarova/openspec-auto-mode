# Runs stopped by a limit: continue instead of FAILED-CHECK – plan

Status: plan agreed in principle 2026-11-28, not implemented; open questions in section 8.
Date: 2026-11-28

## 1. Problem (real batch of 2026-11-27)

The last group run of a change (tuning on the emulator) hit `maxTurns`
(200) after 40 min, the most expensive run of the batch. All tasks were ticked and committed and the working tree was
clean, yet the batch stopped:

- every nonzero exit of Claude Code is a write-check problem (`openspec-auto.ps1`, step 3:
  `claude exited with code … error_max_turns`) → outcome **FAILED-CHECK**, batch stops, change 17
  never starts;
- the stop message is always `write-check failed after run N …`, whatever the cause.

`maxBudgetUsdPerRun` (`--max-budget-usd`) ends a run the same way (`error_max_budget_usd`), so a
cost cap would today stop the batch too – it protects money but stops productive work.

## 2. Goal

1. A run stopped by a limit (turns or budget) after real progress does not stop the batch: the
   next run continues with an empty context.
2. A run stopped by a limit without progress stops with a clear message and a cause, not
   FAILED-CHECK; the next start continues the change.
3. Uncommitted work of an interrupted run is not lost, not hoarded in `git stash`, and the next run
   can build on it.
4. Every stop message names its real cause (also in the Pushover notification and the report).

## 3. Limit stop: detection and rules

A **limit stop** is a run whose `out.json` has subtype `error_max_turns` or `error_max_budget_usd`
(nonzero exit). Timeouts (`timeoutMinutes`, process killed by the runner) are not included
(open question 2).

All other write-checks still apply: branch unchanged, no push (remote refs), `openspec validate
--specs` and of the change, frozen acceptance tests untouched, no `fix-<change>` from a fix. Any of
these failing → FAILED-CHECK as today. Only the exit code and the dirty tree are judged differently:

| State after the run | New behaviour |
|---|---|
| tasks ticked (done count grew), tree clean | treated as **CONTINUE**; if a group was completed, the group tests run first, as today |
| tasks ticked, tree dirty | leftovers saved (section 4), then **CONTINUE** |
| repair run | leftovers saved if any, then CONTINUE; the group tests decide, as today |
| no progress (group or final run) | leftovers saved if any, outcome **STOPPED** with a clear message (section 5) |

Safeguard: at most **2 limit stops in a row** within a change (open question 3), then STOPPED
(`run N of 16 hit the turn limit again; …`). `maxRunsPerChange` still applies.

## 4. Leftovers of an interrupted run (options B + C, D later)

The worker commits after every finished task (`worker-prompt.md`, step 2), so leftovers are only
the uncommitted part of the one task in progress: edited code, new untracked files, notes in the
change artifacts, temporary files not covered by `.gitignore`. Ignored files (`node_modules`, build
output, `.openspec-auto/`) are never included. On 2026-11-27 the tree was clean after every run,
so this is expected to be rare.

**B – leftovers as a hint for the next run.** When a limit stop leaves a dirty tree, the runner:

1. stashes the leftovers with the existing `Save-Leftovers` (message `openspec-auto: leftovers …`),
2. writes them as a patch to `.openspec-auto/leftovers/<change>-runNN.patch`
   (`git stash show -p --include-untracked stash@{0}`; check the git version supports it),
3. adds to the next run's unit text (wording agreed 2026-11-28):

   > The previous run was interrupted by a limit during task 5.2. Its uncommitted work is in
   > `.openspec-auto/leftovers/16-run05.patch`. Read it; if it is correct, use it as the starting
   > point; fix or redo whatever is wrong or unfinished.

   The task id comes from the first open task of the unit. The hint is not "continue blindly": the
   interrupted run may have been stuck on a wrong approach. The patch is never deleted by the hint.

   To check: the worker may read `.openspec-auto/` (the prompt forbids only editing it) and the
   settings do not deny reading that folder.

**C – tidy up after success.** When a change ends SUCCESS (or NONCRITICAL), the runner drops the
runner-made stashes of that change from `git stash` (only entries found by `Get-LeftoverStashes`
whose message names the change; the patch files already hold their content). The report gets a
line like `2 leftovers of 16 kept as patches in .openspec-auto/leftovers/`. On STOPPED / BLOCKED /
FAILED-CHECK the stashes stay, the user may want to look at them.

**D – manual clean-up (later, optional).** `openspec-auto.ps1 -CleanLeftovers`: lists the patch
files and deletes them after confirmation. Never automatic.

## 5. Clear stop messages

Replace the single `write-check failed …` with a message by cause, e.g.:

- `run 5 of 16 hit the turn limit (maxTurns 200) without finishing a task; the task is probably too large – split it in tasks.md or raise maxTurns`
- `run 5 of 16 hit the budget limit (maxBudgetUsdPerRun 8) without finishing a task; …`
- `run 5 of 16 timed out after 60 min`
- `agent left branch …`, `working tree not clean`, `possible push`, `frozen acceptance tests changed`, `openspec validate failed`

The same text goes to `stopReason`, the 🛑 notification and the report. When several problems
occur, the first line names the most important one and the notes list all.

## 6. Steps

1. This plan → short spec decisions where needed (no separate spec unless the open questions
   change the design).
2. Runner: limit-stop detection, progress rules (section 3), safeguard, leftovers B + C, messages.
3. Tests: `tests/fake-claude.ps1` gets a limit mode (subtype `error_max_turns` /
   `error_max_budget_usd`, nonzero exit, optionally ticks a task and/or leaves files); checks for
   every row of the table, the safeguard, patch file + hint in the next prompt, stash dropped after
   SUCCESS and kept after STOPPED, messages. Full suite in the background (~15 min).
4. Docs: GUIDE and README (what happens at a limit, recommend `maxBudgetUsdPerRun`, leftovers
   folder), appendix rows.
5. Optional paid check on a real project (e.g. a mobile project with a low `maxTurns`); cost estimate
   first, needs ok.

Each step needs the user's ok; commit with the noreply address; push/merge only on request.

## 7. Benefits and risks

Benefits: the batch does not stop needlessly (the change would have gone on to group tests,
archive and the next change); a budget cap becomes usable; less work done twice; stops say why.

Risks:
- more money spent unattended where the batch used to stop → safeguard of 2 limit stops in a row,
  `maxRunsPerChange`, and a budget cap;
- the next run may adopt wrong partial code from the patch → group tests catch it;
- a task ticked and committed while not really done → exists already today, group tests catch it;
- patch files pile up in `.openspec-auto/leftovers/` → small, ignored by git; option D later.

## 8. Open questions

1. ~~Dirty tree at a limit: stash and continue, or stop?~~ Decided 2026-11-28: patch + hint (B),
   tidy-up after success (C), continue.
2. Include timeouts (`timeoutMinutes`) in the limit-stop rules? Recommendation: not now.
3. Safeguard of 2 limit stops in a row: enough?
4. Before implementing: evaluate the next real batch (costs, limits, stops) and adjust.
