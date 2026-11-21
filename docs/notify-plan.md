# Push notifications from the runner: spec

Status: spec agreed (section 11); step 1 (runner + tests) implemented on branch `notify`.
Date: 2026-11-21

## 1. Goal

Today the only way to see that auto-mode is still running is to watch `openspec/changes/` and wait
for folders to move to `archive/`. The runner should send a push notification (Pushover, through the
user's existing `C:\claude-notifier\send-notify.ps1`) when a change is done and when the run ends.
Every notification names the project, because several runners can run at the same time in
different projects.

## 2. Principles

- **The runner sends, not the agent.** Only the runner knows a change is really done (archived,
  tests run by the runner green). A notification never repeats what the agent merely claims.
- **No secrets in this repo.** The runner calls an external script; the Pushover keys stay in that
  script's `.env`. The runner never reads or logs them.
- **A notification can never break or stop a run.** Every failure becomes a warning in the report.
- **Off by default.** Without `notifyScript` nothing changes.

## 3. Configuration (`openspec/auto-mode.json`)

| Key | Default | Meaning |
|---|---|---|
| `notifyScript` | `null` | Path to a PowerShell script taking `-Message <string>` and `-Priority <int>` (optional `-Title <string>`). `null` = notifications off. |
| `notifyProjectName` | `null` | Name shown in notifications. `null` = name of the project folder (`Split-Path -Leaf $Project`). |
| `notifyStopPriority` | `1` | Pushover priority for a stop/crash (`1` = high, `2` = emergency, repeats until acknowledged). |
| `notifyTimeoutSeconds` | `30` | How long one send may take before the script is killed. |

Template `templates/auto-mode.json` gets `"notifyScript": null`. A relative path is resolved against
the project root. The start check (and `-DryRun`) fails with exit 2 if `notifyScript` is set but the
file does not exist, so a typo is found before an hour of unattended work, not after it.

## 4. Events and messages

`<P>` = project name (section 5). Counts `k/n` refer to the numbered changes of this run.

| # | When (in `openspec-auto.ps1`) | Title | Message | Priority |
|---|---|---|---|---|
| E1 | start checks passed, before the first worker run (not in `-DryRun`) | `<P>` | `▶ auto-mode started: n changes, first 01-name` | 0 |
| E2 | change result `SUCCESS` (row added to `$results`) | `<P>` | `✅ 03-login done (k/n) · 3 runs · 1.20 USD · 14 min` | 0 |
| E3 | change result `NONCRITICAL` | `<P>` | `⚠ 04-export done with a noncritical issue (k/n); fix-04 next` (or `waits for you`) | 0 |
| E4 | fix change `SUCCESS` | `<P>` | `✅ fix-04 fixed 04-export` | 0 |
| E5 | end of run, no stop reason | `<P>` | `🏁 auto-mode finished: n/n done · 2.75 USD · 1 h 12 min` | 1 |
| E6 | end of run with a stop reason (BLOCKED, FAILED-CHECK, STOPPED, red tests…) | `<P>` | `🛑 auto-mode stopped at 04-export: <short reason>` | `notifyStopPriority` |
| E7 | unhandled exception (the outer `finally`) | `<P>` | `💥 auto-mode crashed: <exception message>` | `notifyStopPriority` |

Notes:
- E1 answers "did it really start" when the run is launched and left alone.
- E5/E6 are the last message of a run; after them nothing else comes from that run. Silence after
  E1 without E5/E6/E7 means it is still working (or the PC went to sleep).
- The stop reason in E6 is shortened to ~200 characters; the full text is in the report. The
  message ends with `report: .openspec-auto/auto-mode-report.md`.
- No code, test output, diffs or file contents are ever sent, only names, counts, cost and time.

## 5. Project name and parallel runs

- The name comes from `notifyProjectName`, otherwise from the project folder name.
- It goes into the **title**, so it is visible in the collapsed notification on the phone.
- If the script has no `-Title` parameter (the runner checks with `Get-Command <script>` and
  `.Parameters`), the name goes to the start of the message instead: `[<P>] ✅ 03-login done …`.
  So it works with the current `send-notify.ps1` too, only the title stays "Claude caka".
- Parallel runs need no coordination: each runner process sends its own notifications, there is no
  shared state, file or lock. Two projects with the same folder name are told apart by setting
  `notifyProjectName`.

## 6. Delivery and failure handling

- New helper `Send-Notify([string]$Message, [int]$Priority)` in the helpers section.
- The script is started as a child process (`powershell -NoProfile -ExecutionPolicy Bypass
  -EncodedCommand …`) through the existing `Invoke-Process`, timeout `notifyTimeoutSeconds`.
  A separate process means the script cannot change runner state (variables,
  `$ErrorActionPreference`, current directory), and a hanging network call is killed.
- Message, priority, title and script path are passed through environment variables
  (`OSA_NOTIFY_*`), never on a command line, so quotes, `%`, `|` and diacritics cannot break it.
- Non-zero exit, timeout or exception → `$warnings += "notification failed: …"`, the run continues.
  After 3 failures in a row the runner stops trying for the rest of the run (one warning about it),
  so a dead network does not add 30 s to every change.
- Duration of a send is not counted into the change time.

## 7. Change to `C:\claude-notifier\send-notify.ps1` (outside this repo, separate step)

Add an optional parameter, backward compatible:

```powershell
[string]$Title = "Claude caka"
```

and use `$Title` instead of the fixed `"Claude caka"` when encoding the title. Existing calls
without `-Title` behave exactly as now.

Also: the script prints `CHYBA` but exits 0 when the Pushover request fails (it exits 1 only for
missing keys). Add `exit 1` at the end of its `catch` block, otherwise the runner cannot see a
failed send.

## 8. Tests (`tests/run-tests.ps1`)

A fake notify script `tests/fake-notify.ps1` appends each call (`title|priority|message`) to a file
given by an environment variable. New cases:

1. `notifyScript` null → no call, behaviour as before.
2. Two changes SUCCESS → calls E1, E2, E2, E5 in this order; titles contain the project name;
   E5 priority 1.
3. BLOCKED change → E1, E6 with `notifyStopPriority`; no E5.
4. NONCRITICAL with `fixMode=immediate` → E3 then E4.
5. Fake script without `-Title` → project name is the message prefix.
6. Fake script that exits 1 / sleeps past the timeout → run result unchanged, warning in the report,
   at most 3 attempts.
7. `notifyScript` pointing to a missing file → start check fails with exit 2.
8. `notifyProjectName` set → used instead of the folder name.

## 9. Documentation

- `README.md` / `GUIDE.md`: short section "Notifications" with the config keys and a link to the
  Pushover guide (`scratch\VZOR\claude-notifier-navod.md`) as an example script.
- `claude-skill/openspec-auto/SKILL.md`: during setup, ask whether to enable notifications and
  which script to use.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Notification failure hides a real run problem | Failure is only a warning; the run result never depends on it. |
| Too many messages on long runs | Only one per change + start + end; no per-run or per-group messages. |
| Emergency priority (2) on every stop is annoying at night | Default is 1; 2 only by choice. |
| Script path with spaces / execution policy blocks the script | `-File` with a quoted path and `-ExecutionPolicy Bypass` for the child process only. |
| Project names leave the PC (Pushover servers) | Only folder/change names and numbers are sent; documented in section 4. |

## 11. Decisions (2026-11-21)

1. E1 (start message): kept.
2. Default `notifyStopPriority`: 1.
3. E5 (finished): priority 1.

## 12. Implementation steps (each needs an explicit ok)

1. Runner: config keys, start check, `Send-Notify`, events E1–E7, tests from section 8.
2. `send-notify.ps1`: optional `-Title` (section 7), then one real test message.
3. Docs and skill (section 9).
4. Trial on a real project with a short run of two changes.
