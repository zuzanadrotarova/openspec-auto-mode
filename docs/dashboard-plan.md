# Cost and run dashboard – plan

Status: steps 2–6 implemented 2026-11-28 (dashboard.ps1, page, hook, shortcuts, runner import at the end of a start, tests, docs). History files are rewritten by key (not append-only). Date: 2026-11-28.
Order agreed: this comes after `docs/limit-continue-plan.md`, except the import (step 2), which
should run before 2026-12-08 (see section 2).

## 1. Goal

One local overview across all projects: how auto-mode ran and what every project cost in total,
split into

1. **auto-mode** – runs of the runner,
2. **spec preparation** – interactive Claude Code sessions with OpenSpec planning work,
3. **other interactive work** – evaluation, debugging, anything else in the project.

History must survive deleted or re-cloned projects and Claude Code's transcript clean-up. Data stay
on this PC (local HTML page, no server, no upload).

## 2. Data sources (checked on a real project, 2026-11-28)

**Auto-mode runs:** `<project>/.openspec-auto/runs/<stamp>/<change>.runNN.out.json` – written by
Claude Code (`--output-format json`): `total_cost_usd`, `usage` (input, cache read/creation,
output, thinking), `modelUsage` per model with `costUSD`, `num_turns`, `duration_ms`, `subtype`,
`session_id`; plus `auto-mode-report.md` and `last-run.json` per start. Workers run with
`--no-session-persistence`, so they leave no transcript. The folder is git-ignored and lives only
in the project.

**Interactive sessions:** `~/.claude/projects/<encoded project path>/<session id>.jsonl`. The
file ends with a `cost-state` record: `totalCostUSD`, `modelUsage` per model (tokens, `costUSD`),
durations, lines added/removed, `startTime`. Each assistant message also has `model` and `usage`;
skill calls and tool use are visible in the messages. In the checked project the interactive
sessions cost about as much as its auto-mode runs.

Costs are list-price values computed by Claude Code (`costBasis: list`); with a subscription they
show the value of usage, not money paid.

Transcripts are deleted after `cleanupPeriodDays` – raised from the default 30 to **90** in
`~/.claude/settings.json` on 2026-11-28. Without it the session of 2026-11-08 would be gone
around 2026-12-08.

## 3. Central history

One folder outside the projects: `%USERPROFILE%\.openspec-auto\history\` with append-only JSONL
files, one record per unit:

- `runs.jsonl` – one record per auto-mode run: project (path + name), change, run number, start
  and end, model(s), tokens by kind, cost, turns, subtype, outcome of the change, stop reason,
  available memory, `session_id`.
- `sessions.jsonl` – one record per interactive session: project, session id, start, end, cost
  and tokens per model, lines added/removed, skills used, category (section 4).

Records are keyed (project + run stamp + change + run, or session id); re-imports update a record
instead of duplicating it. Only summary numbers and names are stored – no prompts, no code, no
conversation text.

## 4. Category of an interactive session

Decided per session from the skills and commands it used:

- **spec preparation** – `openspec-propose`, `openspec-explore`, `openspec-update-change`,
  `openspec-sync-specs`, `openspec` (or `openspec new/instructions` commands);
- **other** – everything else, including `openspec-auto` (setting up, starting, evaluating),
  `openspec-verify-change`, `openspec-archive-change`;
- **mixed** – both kinds appear; the dashboard shows it separately.

Limit: the cost is known per session, so a mixed session is not split. Splitting by message would
need a price list (later, if needed). The skill lists are in the config, editable.

## 5. Collection

1. **Runner:** after every run it appends the record to `runs.jsonl` (in addition to the project
   files). Failure to write the history is a warning, never a stop.
2. **SessionEnd hook** (user settings, all projects): a small PowerShell script reads the ended
   session's transcript and appends the record to `sessions.jsonl`. Must be fast and never fail
   loudly (errors to a log file only). Projects not using OpenSpec can be filtered out or kept as
   "other" (open question 2).
3. **Import script** `dashboard.ps1 -Import`: scans all `~/.claude/projects/*` transcripts and the
   `.openspec-auto/runs/` folders of known projects (project paths come from the transcripts'
   `cwd`), fills both files. Run once now, then any time as a repair.

## 6. Dashboard page

`dashboard.ps1` (or `openspec-auto.ps1 -Dashboard`) builds one self-contained HTML file from the
history (data embedded, no server, works offline) and opens it in the browser.

- **All projects:** total cost per project split into auto-mode / spec preparation / other /
  mixed; trend over time (per week); cost by model.
- **Project:** changes with outcome, runs, cost, duration, turns, limit stops; interactive sessions
  with date, category, cost; ratio preparation : auto-mode.
- **Change:** its runs (group, mode, turns, cost, tokens, subtype, stop reason).
- **Tokens:** share of cache reads vs new input vs output (what drives the cost).
- Top 10 most expensive runs and sessions.

## 7. Steps

1. Spec decisions (open questions), this plan updated.
2. Import script + history format; run the import before 2026-12-08; check the numbers against
   the project's auto-mode report and the session totals.
3. Runner writes `runs.jsonl`; tests with the fake agent.
4. SessionEnd hook + install step in `install.ps1`; tests with a sample transcript.
5. Dashboard HTML generator; check with real data in the browser.
6. Docs (README, GUIDE).

Each step needs the user's ok; nothing that touches a running auto-mode while a batch runs.

## 8. Benefits and risks

Benefits: one overview of the real cost of a project (preparation was about as expensive as
auto-mode in the checked project); history survives clean-up and deleted projects; basis for decisions
(model, budget cap, size of task groups).

Risks:
- the transcript and `out.json` formats are Claude Code internals and may change → import reads
  only a few fields, tolerates missing ones, and the hook never blocks a session;
- category by skills is approximate (mixed sessions);
- the central history is a new file to back up (small);
- a hook runs at the end of every session in every project → it must be quick and silent.

## 9. Decisions (2026-11-28)

1. Central folder `%USERPROFILE%\.openspec-auto\history\` – ok.
2. Sessions of projects without OpenSpec are collected too (category "other").
3. Skill lists for "spec preparation" (section 4) – ok.
4. The most user-friendly form: the user never runs a script by hand.
   - A separate `dashboard.ps1` does the work (independent of the runner, safe while a batch runs).
   - The page `%USERPROFILE%\.openspec-auto\dashboard.html` is rebuilt automatically at the end
     of every auto-mode start and by the SessionEnd hook, so it is always current.
   - `install.ps1` creates a desktop and Start menu shortcut "OpenSpec dashboard" that just opens
     that page (double-click).
   - The `openspec-auto` skill also reacts to "ukáž dashboard / koľko to stálo": it rebuilds the
     page, opens it and answers with a short summary in the chat.
