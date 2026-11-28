---
name: openspec-auto
description: OpenSpec auto-mode – unattended implementation of numbered OpenSpec changes (01-…, 02-…), each in a fresh Claude Code process with an empty context. Use when the user wants to set up auto-mode in a project, check readiness, start it, or see its report ("openspec-auto", "auto-mode", "spusti auto-mode", "priprav projekt na auto-mode", "ako dopadol auto-mode").
argument-hint: "[init | check | acceptance <change> | run | report]"
---

# OpenSpec auto-mode

The user works only inside Claude Code and never runs PowerShell commands by hand. You run everything for them and explain results in their language (Slovak, unless they write otherwise). Keep answers short: what happened, what it means, what to do next.

Runner: `{{OPENSPEC_AUTO_HOME}}\openspec-auto.ps1`
Guide (error messages and fixes): `{{OPENSPEC_AUTO_HOME}}\GUIDE.md`

If the paths above still contain the placeholder OPENSPEC_AUTO_HOME in double curly braces, the skill was copied by hand instead of installed. Stop and tell the user to run `install.ps1` from the cloned openspec-auto-mode repository (`powershell -ExecutionPolicy Bypass -File install.ps1`), then restart Claude Code.

Invoke it with the PowerShell tool, always with the project root as `-Project`:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "{{OPENSPEC_AUTO_HOME}}\openspec-auto.ps1" -Project "<project root>" [-Init | -SetupAcceptanceSchema | -DryRun | -Background]
```

The project root is the git repository root of the current working directory (`git rev-parse --show-toplevel`).

Exit codes: `0` = OK, `1` = the loop stopped (BLOCKED / FAILED-CHECK / STOPPED), `2` = start checks failed, nothing ran. With `-Background`: `0` = the run started in its own window, `2` = it did not start.

## Choose the mode from the argument

| Argument | Mode |
|---|---|
| `init` | Set up the project |
| `check` | Readiness check only |
| `acceptance <change>` | Write the acceptance tests of a change with the user |
| `run` | Start auto-mode |
| `report` | Summarize the last report |
| none | `check`; if everything passes, ask whether to start it |

## init – set up the project

1. If it is not a git repository, ask before running `git init -b main`. If git `user.email` is not set, ask the user for name and e-mail and set them with `git config` (local to the repository).
2. If `openspec/` does not exist, run `openspec init --tools claude`.
3. Run the runner with `-Init`. It creates `openspec/auto-mode.json` and the local git exclusion.
4. Fill in `openspec/auto-mode.json` from the project itself, do not ask what you can find out:
   - `testCommand`: from `package.json` (`scripts.test` → `npm test`), `pyproject.toml` / `pytest.ini` (`pytest`), `*.csproj` / `*.sln` (`dotnet test`), `Cargo.toml` (`cargo test`), `go.mod` (`go test ./...`), etc.
   - `allowedCommands`: build and lint commands the project actually has (e.g. `npm run build`, `npm run lint`). Remove template entries the project does not have. Also add scripts the tests or the build call themselves: look into `package.json` scripts and folders such as `tools/` and `scripts/` (e.g. `node tools/gen.js`); a command missing here is denied to the agent (`permission denied`).
   - If the project has no tests or no code yet, say so and ask what the test command will be.
   - A script in the project root needs an explicit path (`.\test.cmd`); the tests must pass and must not leave untracked files (add test outputs such as coverage to `.gitignore`).
5. Memory settings: detect the stack from the files in the project root and its subfolders and propose the matching entries. Show the proposal as a short table and write only what the user confirms.

   | Found | `memoryCleanupCommands` | `keepProcesses` | Memory limit in the project (optional) |
   |---|---|---|---|
   | `gradlew` / `build.gradle(.kts)` | `.\gradlew --stop` (stops all Gradle daemons of that version, also Android Studio's) | – | `gradle.properties`: `org.gradle.jvmargs=-Xmx3g`, `kotlin.daemon.jvmargs=-Xmx2g`, `org.gradle.workers.max=2` |
   | Android (`AndroidManifest.xml`, `app/build.gradle*`) | as Gradle | `qemu-system-*`, `emulator*`, `adb` if the tests need an emulator | as Gradle |
   | `pom.xml` + `.mvn/` with mvnd | `mvnd --stop` | – | – |
   | `*.csproj` / `*.sln` | `dotnet build-server shutdown` | – | – |
   | `WORKSPACE` / `MODULE.bazel` | `bazel shutdown` | – | `.bazelrc`: `startup --host_jvm_args=-Xmx3g` |
   | `docker-compose.yml` / `compose.yaml` | `docker compose stop` only if the tests do not need the containers; otherwise nothing | – (Docker runs outside the run) | – |
   | `package.json` | – (Node ends with the run) | – | `NODE_OPTIONS=--max-old-space-size=4096` only if builds ran out of memory before |
   | iOS (`*.xcodeproj`, `ios/`) | – (Windows cannot build it) | – | – |

   Cleanup commands run only when memory is low, at most every 10 minutes, and must not change files in the working tree. `keepProcesses` are names with wildcards, without `.exe`; memory recovery never stops them. A memory limit is a project change: explain it in one sentence and commit it only after the user's ok. If nothing fits, leave both lists empty and say that the generic recovery (stopping leftover processes of the runs, waiting) still works.
6. Offer acceptance tests (recommended when the project has tests): set `acceptanceMode: "reviewed"`, `acceptanceCommand` (e.g. `node --test "acceptance/{change}/*.accept.js"`) and `acceptanceDir`, then run the runner with `-SetupAcceptanceSchema`. It adds an `acceptance` artifact to the project's OpenSpec workflow (proposal, specs, design, **acceptance**, tasks), so `/opsx:propose` writes the acceptance tests with the user as part of every change. Say that this uses OpenSpec's custom schemas, which are experimental; after an OpenSpec update, run `-SetupAcceptanceSchema` again.
7. Offer push notifications: ask whether the user wants a message on the phone when a change is done and when the run ends, and which notify script to use (a PowerShell script taking `-Message`, `-Priority` and optionally `-Title`, e.g. `C:\claude-notifier\send-notify.ps1`; check that the file exists, never read or print its keys or `.env`). Set `notifyScript` to its absolute path; set `notifyProjectName` only if the folder name is not a good name. Without an answer leave `notifyScript` at `null`.
8. Add `.gitattributes` with `* text=auto eol=lf` if the project has none.
9. Commit the setup (`Setup OpenSpec auto-mode`). The runner needs a clean working tree.
10. Tell the user the next step: propose changes named `01-…`, `02-…` (e.g. `/opsx:propose 01-login: …`), commit them, then `/openspec-auto run`. Mention that `tasks.md` should be split into groups that are logical units with their own tests ("1. Login form (code + tests)"), because the runner tests after every group.

## check – readiness

Run with `-DryRun`. Lines starting with `+` passed, lines starting with `x` are problems. The check also runs the project's tests once (as long as the tests take); `baseline tests fail` means the project must be green before auto-mode starts. Read only the end of `.openspec-auto/baseline-tests.txt` to explain why.
- Explain each problem in one sentence with the concrete fix (see the table in the appendix of GUIDE.md).
- Offer to fix what you can: commit a dirty tree, rename a change folder to `NN-name`, complete a missing artifact via `/opsx:update`, fix a validation error.
- Do not fix architectural content of a change on your own; propose the fix and let the user decide.
- If everything passes, show the plan (order of changes).

## acceptance – write acceptance tests with the user

Used when `openspec/auto-mode.json` has `acceptanceMode: "reviewed"`, or when the user wants it (then offer to set `acceptanceMode`, `acceptanceCommand` and `acceptanceDir`). This is interactive: the user owns these tests, the auto-mode agent can never change them. With the acceptance schema (`-SetupAcceptanceSchema`), `/opsx:propose` does this as the `acceptance` artifact; this mode is for changes created before, or to redo the tests of one change. If the change's schema has the artifact, also write `openspec/changes/<change>/acceptance.md` (the table scenario -> test).

1. Read the change's spec deltas (`openspec/changes/<change>/specs/**`), `proposal.md` and `design.md`.
2. Propose one test per `#### Scenario:` whose name contains the exact scenario name (e.g. `test('Scenario: <name>', ...)`; with `scenarioCoverage` the runner refuses the start otherwise), plus edge cases the scenario implies. Use the API named in `design.md` / `tasks.md` (module path, function names), more than one example per scenario, and no helper files outside `acceptanceDir/<change>/`.
3. Write them into `acceptanceDir/<change>/` with a name `testCommand` does not pick up (with `node --test`: `*.accept.js`, not `*.test.js`).
4. Run `acceptanceCommand` for the change: the tests must fail because the code is missing, not because of a mistake in the test itself.
5. Show the user the tests in short (scenario: what is checked) and let them confirm or correct. Commit only after their ok (`<change>: acceptance tests`).

## run – start auto-mode

1. Run `check` first. If it fails, stop and explain, do not start. A warning `only x GB memory available` is not an error: name the biggest processes from the warning and suggest closing what the user does not need (emulator, Android Studio, browsers), then start if they agree.
   Night checklist (always before a long or unattended run; read-only, you never close programs or change settings yourself):
   - Memory: show the 8 biggest processes (`Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 Name, @{n='GB';e={[math]::Round($_.WorkingSet64/1GB,1)}}`) and the commit charge (`Get-CimInstance Win32_OperatingSystem`: used = `TotalVirtualMemorySize - FreeVirtualMemory`, in % of `TotalVirtualMemorySize`). Suggest what to close; say that Claude Code itself may be closed after the start (about 2 GB more).
   - Entries of `keepProcesses` (e.g. an emulator) must already be running before the start; programs started inside the run end with it.
   - Graphics driver updates: a driver installed during a run can crash the emulator and the terminal. If a GPU vendor updater runs (`Get-Process` names like `RadeonSoftware`, `AMDRSServ`, `NVIDIA app`, `DSATray`), remind the user to switch off automatic driver updates in that program and update by hand in the daytime.
   - Windows Update: read `HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` (`PauseUpdatesExpiryTime`, `ActiveHoursStart`, `ActiveHoursEnd`). If updates are not paused and the night is outside the active hours, suggest pausing updates for a day or moving the active hours (Settings → Windows Update), so the PC does not restart at night.
   Show it as a short list; the user decides, then start.
2. Start the runner with `-Background`, in the foreground (no `run_in_background`). It starts the run in its own minimized window named `openspec-auto: <project>`, outside Claude Code, and returns within about 20 seconds:
   - exit `0`: note the PID from `auto-mode started in its own minimized window (PID n)`. If it says `still starting`, read `.openspec-auto/running.json` (`phase` becomes `running`) and `.openspec-auto/last-run.json` a minute later.
   - exit `2`: the run did not start; explain the reason it prints (`the run ended at once (failed-start): …`, `already running`).
3. Start a waiter with the PowerShell tool and `run_in_background: true`: `Wait-Process -Id <PID>`. It uses almost no memory and tells you when the run ends. Do not poll. If the waiter is killed, the run goes on; only that notice is missing.
4. Tell the user it is running: the plan (changes in order), that every change, and every batch of tasks within a large change, runs in a new process with an empty context, and that they will get a summary at the end (and, if `notifyScript` is set, phone notifications after every change and at the end). Also say that the run is in its own window: they may close Claude Code and the terminal, the run goes on; closing that window stops the run (the next start resumes it).
5. While it runs, do not touch the project: no file edits, no git commands that change the working tree or branches, no OpenSpec commands that write. If the user asks for progress, read `.openspec-auto/running.json` (change, run) and only the last ~30 lines of the `console.txt` it names.
6. To stop a run on the user's request: `Stop-Process -Id <pid from running.json>`. Its worker and tests end with it; the next `run` stashes unfinished files and resumes.
7. When the waiter ends, continue with `report`.

## report – summarize the result

First look at the state files in `.openspec-auto/`:
- `running.json` exists and its `pid` is a living process → the run is still going; say which change and run, and stop here.
- `running.json` exists but the process is gone → the run was interrupted (closed window, restart, power cut, killed); say during which change and run. The next `/openspec-auto run` resumes it and puts unfinished files into a `git stash` first; nothing is lost.
- `last-run.json`: `state` (`finished`, `stopped`, `crashed`, `failed-start`) and `reason` of the last run. For `failed-start` there is no new report; explain the reason.

Then read `.openspec-auto/auto-mode-report.md` in the project root and summarize:
- each change and its result:
  - SUCCESS = done, and the runner's own test run passed (`Tests` column); the notes show the test result after each task group (`groups: 1 green, 2 red->green (1 repair)`),
  - NONCRITICAL = done, but a `fix-…` change was created; if the tests failed, the runner processed the fix right away and it has its own row (`fixes NN-…`), otherwise the fix waits for the user,
  - BLOCKED = architectural problem, the loop stopped,
  - FAILED-CHECK / STOPPED = the runner's check failed (`agent changed frozen acceptance tests` = the agent touched the acceptance folder; show the commit with `git log -p -- <acceptanceDir>/`),
  - not processed = the loop never reached it;
- STOPPED with `ran out of memory` (runner tests) or `worker ran out of memory` = the PC was short of memory, not a code problem; no repair was paid for. Suggest closing other programs (the warnings name the biggest processes) and `/openspec-auto run` again; it continues where it stopped;
- `## Stashed leftovers`: unfinished files of an interrupted or out-of-memory run. Explain that `git stash show -p stash@{n}` shows them and `git stash drop stash@{n}` deletes them; the work itself is redone by the run. Never drop a stash without the user's ok;
- total cost, and the `fix-…` changes waiting for the user;
- **BLOCKED:** summarize `openspec/changes/<change>/BLOCKED.md` (what blocks, options) and explain the way out. The user decides; you then help fix it, delete `BLOCKED.md`, commit, and `/openspec-auto run` again.
- **FAILED-CHECK:** read the reason in the report notes. If needed, read only the `result` and `permission_denials` fields of the named log `.openspec-auto/runs/<time>/<change>.runXX.out.json`, never whole logs. When the tests failed, read only the end of the named `.tests.txt` log. Explain it and propose a fix. The tests must be green before the next start (an interrupted `fix-…` change is the exception: the runner resumes it).
- **Everything OK:** offer to review and merge. The last `auto/…` branch contains all changes (`git log --oneline main..auto/<last>`, then `git checkout main` and `git merge auto/<last>`). Merge only when the user agrees.
- `fix-…` changes: offer `/opsx:apply fix-…` interactively, or renaming them to a numbered change for the next auto-mode run.

## Rules

- Never push and never merge without the user's explicit consent.
- Do not run the runner twice at the same time in the same project.
- Do not read files in `.openspec-auto/runs/` beyond what the report points to. Logs are large and would only fill this conversation's context.
