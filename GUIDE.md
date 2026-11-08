# Guide: how to use OpenSpec auto-mode

You do everything in Claude Code, in a terminal (e.g. Warp). You do not type any PowerShell commands; Claude runs them for you through the `/openspec-auto` command.

**Installation (once per machine):** clone the repository and run `install.ps1`, then restart Claude Code:

```powershell
git clone https://github.com/zuzanadrotarova/openspec-auto-mode.git
cd openspec-auto-mode
powershell -ExecutionPolicy Bypass -File install.ps1
```

You need Windows, Claude Code, OpenSpec (`npm install -g @fission-ai/openspec`) and git.

## Quick overview

### Commands (work in every project)

| Command | What it does |
|---|---|
| `/openspec-auto init` | Sets up the project (once per project). Finds out how the project runs tests, build and lint, configures it and commits. |
| `/openspec-auto check` | Checks readiness, runs nothing. If something is wrong, explains what is missing and offers a fix. |
| `/openspec-auto run` | Starts auto-mode in the background. Ask about progress any time; you get a summary at the end. |
| `/openspec-auto report` | Summarizes the last result, including what to do next for BLOCKED or `fix-` changes. |
| `/openspec-auto` | Check, and if everything is fine, asks whether to start. |

### Plain language works too

- "set up the project for auto-mode"
- "start auto-mode"
- "how is it going?" (while running)
- "how did auto-mode go?"
- "show me what auto-mode changed"
- "merge it into main"

### The whole flow on one screen

```
/openspec-auto init                         # once per project
/opsx:propose 01-name: …                    # for each change (01-, 02-, … = order)
"commit the proposals"
/openspec-auto check                        # readiness check
/openspec-auto run                          # start, summary at the end
"show me what auto-mode changed"            # review the result
"merge it into main"                        # after the review
```

### Why the context does not fill up

The actual work is done by separate Claude Code processes, each with an empty context. A large change is split across several runs. Only a short summary of the report gets into your conversation, never the full logs.

---

## How it works in short

1. **You** propose changes (`/opsx:propose`) and number them in order: `01-…`, `02-…`, …
2. **`/openspec-auto run`** processes them unattended, one after another: implements, tests, archives and commits. Each change gets its own git branch `auto/NN-name`.
3. Every agent run is a **new process with an empty context**. A large change is split across several runs. Nothing is carried between runs through the conversation, only through files, so the context window never fills up.
4. After each run it verifies that everything is written and committed. If not, auto-mode stops.
5. It does not take the agent's word that the tests pass: it runs the tests itself after every task group (the `## 1. …`, `## 2. …` sections of `tasks.md`) and after every finished change. If a group breaks the tests, the next run repairs only that group. It also runs the tests once before it starts; the start has to be green.
6. At the end you get a summary. You review and merge the result. Auto-mode never pushes or merges on its own.

---

## 1. Project setup (once per project)

Open Claude Code in the project folder and type:

```
/openspec-auto init
```

Claude:
- checks git (if the project is not a repository, asks whether to create one),
- installs OpenSpec into the project if it is not there yet,
- creates the configuration `openspec/auto-mode.json` and finds out on its own how the project runs tests, build and lint,
- commits everything.

**Prerequisite:** the project's packages are installed and the tests pass. Auto-mode is not allowed to install packages. The tests must not leave files behind (e.g. a coverage report not listed in `.gitignore`).

### Settings (optional)

To change something, tell Claude (e.g. "use the sonnet model in auto-mode" or "set tasksPerRun to 4"):

| Setting | Meaning | Default |
|---|---|---|
| `testCommand` | test command | found by Claude |
| `allowedCommands` | additional commands the agent may run (build, lint) | found by Claude |
| `tasksPerRun` | how many tasks the agent does in one run, i.e. in one context; fewer = cleaner context, more runs | 8 |
| `maxRunsPerChange` | max. runs per change | 10 |
| `timeoutMinutes` | time limit of one run | 60 |
| `maxTurns` | max. agent turns in one run | 200 |
| `model` | `sonnet` (cheaper), `opus`, … | default model |
| `maxBudgetUsdPerRun` | cost cap of one run in USD | no limit |
| `testTimeoutMinutes` | time limit of one test run by auto-mode itself | 20 |
| `fixMode` | what happens when a change is NONCRITICAL and the tests fail: `immediate` = fix it right away, `stop` = stop and leave it to you | `immediate` |
| `maxRunsPerFix` | max. runs to fix such a bug | 2 |
| `groupTesting` | one task group per run and tests after every group; `false` = faster and cheaper, but tests only at the end | `true` |
| `maxGroupRepairs` | how many times the agent may try to repair a group that broke the tests | 2 |
| `acceptanceMode` | `reviewed` = every change needs acceptance tests, written with Claude and checked by you before the start (section 2); `off` = none | `off` |
| `acceptanceCommand` | how to run the acceptance tests of one change, `{change}` stands for its name | - |
| `acceptanceDir` | folder of the acceptance tests | `acceptance` |

---

## 2. Proposing changes (before each start)

For each change:

```
/opsx:propose 01-login: user login with e-mail and password
```

**Naming:**

| Name | Processed by auto-mode? |
|---|---|
| `01-login`, `02-profile`, `10-export` | Yes, in order of the number |
| `fix-01-login` | Only right after `01-login`, when auto-mode created it and the tests fail (section 4); otherwise it waits for you |
| `login` (no number) | No |

If a change got a different name, ask Claude to rename it (e.g. "rename the change login to 01-login").

**Keep in mind:**
- The number sets the order. If `02` depends on `01`, it must have a higher number.
- Each change must have all parts: `proposal.md`, `design.md`, `tasks.md` and spec deltas.
- Architectural decisions belong in `design.md`. The agent must not deviate from it; if it would have to, it stops and asks you.
- Concrete tasks in `tasks.md` (file, function, what it should do) mean fewer stops.
- Split `tasks.md` into groups (`## 1. …`, `## 2. …`) that are logical units ending in a working state, each with its own tests: "1. Slugify (code + tests)", "2. Truncate (code + tests)". Not "1. Implementation / 2. Tests": then the check after group 1 tests nothing new. Every group costs one agent run (plus one short final run per change).
- Small changes (3 to 10 tasks) work best. Split a large feature into several changes.
- You do not have to propose the whole project at once. A batch is enough; add more changes later.

**Acceptance tests (if `acceptanceMode` is `reviewed`):** for every change, write tests that say when it is done, before auto-mode starts. If the project uses the acceptance workflow (set up by `/openspec-auto init`), `/opsx:propose` writes them with you as one part of the change, next to the proposal, specs, design and tasks. Otherwise tell Claude "write acceptance tests for 01-login" (or `/openspec-auto acceptance 01-login`). Either way you write one test per scenario into `acceptance/01-login/`. The agent cannot change them: if it does, auto-mode stops. They are the strongest check auto-mode has, because they were written before the code, outside auto-mode, and you approved them. Read them before you commit them: a wrong acceptance test stops the change with `BLOCKED`.

When the changes are ready, tell Claude "commit the proposals".

---

## 3. Check and start

```
/openspec-auto check
```

Claude verifies that everything is ready: clean git, numbered changes, each with a complete and valid proposal, no unresolved block, and passing tests (the check runs them, so it takes as long as your tests). If something is missing, it explains what and offers a fix.

```
/openspec-auto run
```

Auto-mode runs in the background, possibly for hours. Claude tells you the order of the changes and sends a summary at the end. Meanwhile:
- do not touch the project (no file edits, no branch switching),
- ask about progress any time ("how is it going?").

---

## 4. Result

You get a summary at the end. `/openspec-auto report` repeats it any time later.

| Result | Meaning | Next step |
|---|---|---|
| **SUCCESS** | Done, archived, and the tests passed when auto-mode ran them itself. | Review and merge. |
| **NONCRITICAL** | Done, but something does not work. A `fix-NN-name` change describing the bug was created. If the tests fail, auto-mode fixed it right away with a fresh agent (the `fix-` row in the summary, same branch); if the tests pass, the fix waits for you. | Review the fix, or do the waiting `fix-` change (section 5.3). |
| **BLOCKED** | Architectural problem, auto-mode stopped. | Decide and resolve (section 5.1). |
| **FAILED-CHECK / STOPPED** | The check after a run failed (nothing written, crash, timeout, no progress, push attempt, tests fail although the agent reported success, the fix did not make the tests pass). Auto-mode stopped. | Claude explains the cause and proposes a fix (section 5.2). |
| **not processed** | The loop never reached the change. | It is processed on the next start. |

### Merge

The branches build on each other, so the last `auto/…` branch contains everything. Tell Claude e.g. "show me what auto-mode changed" and then "merge it into main".

---

## 5. When something goes wrong

Restarting is always the same command, `/openspec-auto run`. It skips finished changes and continues from the first unfinished one.

### 5.1 BLOCKED

1. Claude summarizes what blocks and what the options are (from `BLOCKED.md`).
2. **You decide**, e.g. "change the design so that…", "install package X" or "change the change's scope so that…".
3. Claude resolves it with you interactively, deletes `BLOCKED.md` and commits.
4. `/openspec-auto run`

### 5.2 FAILED-CHECK, STOPPED or interruption

Claude explains the cause and proposes a fix. After the fix, `/openspec-auto run`. The tests must pass again before the next start; the only exception is an interrupted `fix-` change, which auto-mode resumes on its own.

### 5.3 Fix changes `fix-…`

Auto-mode processes a `fix-` change on its own only right after the change it belongs to, and only when the tests fail. The others wait for you (the bug is not visible to the tests, `fixMode` is `stop`, or you wrote the change yourself). Either do them with Claude interactively (`/opsx:apply fix-02-profile`), or say "rename fix-02-profile to a numbered change" and the next `/openspec-auto run` processes it.

### 5.4 More changes

Propose changes with higher numbers (`03-…`, `04-…`), commit them and run `/openspec-auto run`.

---

## 6. Safety

**The agent may:** edit project files, run tests, build, lint and `openspec`, make local commits.

**The agent may not:** push, switch or create branches (auto-mode does that itself), rewrite history, install packages, download from the internet, change auto-mode or Claude Code settings.

Push is blocked by three independent layers: agent permissions, a git hook (active only during auto-mode; outside it you push normally) and a check of remote branches after every run.

Only run auto-mode in projects you trust.

---

## 7. Cost

A small change on the `sonnet` model costs about USD 0.15. The summary shows the cost of each change. Set a cap with `maxBudgetUsdPerRun`.

---

## Appendix: technical details

This is mostly for Claude, not for you.

- **Runner:** `openspec-auto.ps1` with the switches `-Init`, `-SetupAcceptanceSchema`, `-DryRun`, `-Project <path>`.
- **Skill:** `/openspec-auto` lives in `~/.claude/skills/openspec-auto/SKILL.md`; its source is `claude-skill/` in this repository. `install.ps1` installs it and fills in the runner path. After changing the source or moving the repository, run `install.ps1` again.
- **Report and logs:** `.openspec-auto/` in the project (not in git).
- **Runner start-up messages and fixes:**

| Message | Fix |
|---|---|
| `openspec/auto-mode.json missing` | `/openspec-auto init` |
| `testCommand is not set` | set `testCommand` |
| `fixMode … must be 'immediate' or 'stop'` | fix the value in `openspec/auto-mode.json` |
| `baseline tests fail` | make the tests pass first (output in `.openspec-auto/baseline-tests.txt`); a script in the project root needs `.\name.cmd` |
| `testCommand leaves the working tree dirty` | add the listed test outputs to `.gitignore`, delete them, commit |
| `is not a git repository` | `git init` and a first commit |
| `HEAD is detached` | `git checkout <branch>` |
| `git user.email is not set` | `git config user.email …` |
| `working tree is not clean` | commit or discard the changes |
| `no active numbered changes` | propose a change or rename one to `NN-name` |
| `change NN-x is blocked` | section 5.1 |
| `not ready …: missing artifacts: …` | add the missing artifact (`/opsx:update`) |
| `missing artifacts: acceptance (acceptance.md)` | the acceptance tests of that change are not written yet: ask Claude to write them (`/openspec-auto acceptance NN-x`), review and commit |
| `not ready …: openspec validate failed: [ERROR] …` | fix according to the error text |
| `not ready …: tasks.md has no tasks` | add tasks `- [ ] 1.1 …` |
| `branch auto/NN-x exists and diverges` (STOPPED in the report) | switch to that branch or delete it |
| `tests fail after NN-x was archived` (FAILED-CHECK) | the agent reported success but the tests fail; output in the named `.tests.txt` log; fix, commit, run again |
| `tests still fail after N runs (maxRunsPerFix)` (STOPPED) | the automatic fix did not work; do the `fix-` change interactively |
| `group N still red after M repair runs` (STOPPED) | the group broke the tests and the agent could not repair it; look at the named `.tests.txt`, fix interactively, commit, run again |
| `has N open task groups; … needs at least N+1 runs` | raise `maxRunsPerChange`, merge small groups, or set `groupTesting` to `false` |
| `has no acceptance tests (acceptance/NN-x/ ...)` | write and commit the acceptance tests of that change (`/openspec-auto acceptance NN-x`), or set `acceptanceMode` to `off` |
| `acceptanceCommand ... must contain {change}` / `acceptanceMode ... must be 'off' or 'reviewed'` | fix the value in `openspec/auto-mode.json` |
| `baseline tests fail: red (acceptance NN-x exit N)` | an archived change no longer passes its acceptance tests; fix it interactively first. If the tests of a change not yet implemented fail inside `testCommand`, it picks up acceptance tests: rename them (`*.accept.js`) or narrow `testCommand` |
| `agent changed frozen acceptance tests: ...` (FAILED-CHECK) | the agent changed an acceptance test; look at the commit (`git log -p -- acceptance/`), revert it, run again |

- **Tool tests** (no API calls): `tests/run-tests.ps1`.
