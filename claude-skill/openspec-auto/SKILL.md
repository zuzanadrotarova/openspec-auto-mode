---
name: openspec-auto
description: OpenSpec auto-mode – unattended implementation of numbered OpenSpec changes (01-…, 02-…), each in a fresh Claude Code process with an empty context. Use when the user wants to set up auto-mode in a project, check readiness, start it, or see its report ("openspec-auto", "auto-mode", "spusti auto-mode", "priprav projekt na auto-mode", "ako dopadol auto-mode").
argument-hint: "[init | check | run | report]"
---

# OpenSpec auto-mode

The user works only inside Claude Code and never runs PowerShell commands by hand. You run everything for them and explain results in their language (Slovak, unless they write otherwise). Keep answers short: what happened, what it means, what to do next.

Runner: `C:\Users\zuzan\.gemini\antigravity\scratch\openspec-auto-mode\openspec-auto.ps1`
Guide (error messages and fixes): `C:\Users\zuzan\.gemini\antigravity\scratch\openspec-auto-mode\NAVOD.md`

Invoke it with the PowerShell tool, always with the project root as `-Project`:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\zuzan\.gemini\antigravity\scratch\openspec-auto-mode\openspec-auto.ps1" -Project "<project root>" [-Init | -DryRun]
```

The project root is the git repository root of the current working directory (`git rev-parse --show-toplevel`).

Exit codes: `0` = OK, `1` = the loop stopped (BLOCKED / FAILED-CHECK / STOPPED), `2` = start checks failed, nothing ran.

## Choose the mode from the argument

| Argument | Mode |
|---|---|
| `init` | Set up the project |
| `check` | Readiness check only |
| `run` | Start auto-mode |
| `report` | Summarize the last report |
| none | `check`; if everything passes, ask whether to start it |

## init – set up the project

1. If it is not a git repository, ask before running `git init -b main`. If git `user.email` is not set, ask the user for name and e-mail and set them with `git config` (local to the repository).
2. If `openspec/` does not exist, run `openspec init --tools claude`.
3. Run the runner with `-Init`. It creates `openspec/auto-mode.json` and the local git exclusion.
4. Fill in `openspec/auto-mode.json` from the project itself, do not ask what you can find out:
   - `testCommand`: from `package.json` (`scripts.test` → `npm test`), `pyproject.toml` / `pytest.ini` (`pytest`), `*.csproj` / `*.sln` (`dotnet test`), `Cargo.toml` (`cargo test`), `go.mod` (`go test ./...`), etc.
   - `allowedCommands`: build and lint commands the project actually has (e.g. `npm run build`, `npm run lint`). Remove template entries the project does not have.
   - If the project has no tests or no code yet, say so and ask what the test command will be.
5. Add `.gitattributes` with `* text=auto eol=lf` if the project has none.
6. Commit the setup (`Setup OpenSpec auto-mode`). The runner needs a clean working tree.
7. Tell the user the next step: propose changes named `01-…`, `02-…` (e.g. `/opsx:propose 01-login: …`), commit them, then `/openspec-auto run`.

## check – readiness

Run with `-DryRun`. Lines starting with `+` passed, lines starting with `x` are problems.
- Explain each problem in one sentence with the concrete fix (see the table in chapter 7 of NAVOD.md).
- Offer to fix what you can: commit a dirty tree, rename a change folder to `NN-name`, complete a missing artifact via `/opsx:update`, fix a validation error.
- Do not fix architectural content of a change on your own; propose the fix and let the user decide.
- If everything passes, show the plan (order of changes).

## run – start auto-mode

1. Run `check` first. If it fails, stop and explain, do not start.
2. Start the runner **without** `-DryRun` with the PowerShell tool and `run_in_background: true`. It can run for hours. Do not wait for it in the foreground and do not poll; you are notified when it finishes.
3. Tell the user it is running: the plan (changes in order), that every change, and every batch of tasks within a large change, runs in a new process with an empty context, and that they will get a summary at the end.
4. While it runs, do not touch the project: no file edits, no git commands that change the working tree or branches, no OpenSpec commands that write. If the user asks for progress, read only the console output of the background task.
5. When it finishes, continue with `report`.

## report – summarize the result

Read `.openspec-auto/auto-mode-report.md` in the project root and summarize:
- each change and its result:
  - SUCCESS = done,
  - NONCRITICAL = done, but a `fix-…` change was created,
  - BLOCKED = architectural problem, the loop stopped,
  - FAILED-CHECK / STOPPED = the runner's check failed,
  - not processed = the loop never reached it;
- total cost, and the `fix-…` changes waiting for the user;
- **BLOCKED:** summarize `openspec/changes/<change>/BLOCKED.md` (what blocks, options) and explain the way out. The user decides; you then help fix it, delete `BLOCKED.md`, commit, and `/openspec-auto run` again.
- **FAILED-CHECK:** read the reason in the report notes. If needed, read only the `result` and `permission_denials` fields of the named log `.openspec-auto/runs/<time>/<change>.runXX.out.json`, never whole logs. Explain it and propose a fix.
- **Everything OK:** offer to review and merge. The last `auto/…` branch contains all changes (`git log --oneline main..auto/<last>`, then `git checkout main` and `git merge auto/<last>`). Merge only when the user agrees.
- `fix-…` changes: offer `/opsx:apply fix-…` interactively, or renaming them to a numbered change for the next auto-mode run.

## Rules

- Never push and never merge without the user's explicit consent.
- Do not run the runner twice at the same time in the same project.
- Do not read files in `.openspec-auto/runs/` beyond what the report points to. Logs are large and would only fill this conversation's context.
