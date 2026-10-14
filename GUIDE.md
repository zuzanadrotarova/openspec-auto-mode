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
5. At the end you get a summary. You review and merge the result. Auto-mode never pushes or merges on its own.

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

**Prerequisite:** the project's packages are installed and the tests pass. Auto-mode is not allowed to install packages.

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
| `fix-01-login` | No, fix changes wait for you |
| `login` (no number) | No |

If a change got a different name, ask Claude to rename it (e.g. "rename the change login to 01-login").

**Keep in mind:**
- The number sets the order. If `02` depends on `01`, it must have a higher number.
- Each change must have all parts: `proposal.md`, `design.md`, `tasks.md` and spec deltas.
- Architectural decisions belong in `design.md`. The agent must not deviate from it; if it would have to, it stops and asks you.
- Concrete tasks in `tasks.md` (file, function, what it should do) mean fewer stops.
- Small changes (3 to 10 tasks) work best. Split a large feature into several changes.
- You do not have to propose the whole project at once. A batch is enough; add more changes later.

When the changes are ready, tell Claude "commit the proposals".

---

## 3. Check and start

```
/openspec-auto check
```

Claude verifies that everything is ready: clean git, numbered changes, each with a complete and valid proposal, no unresolved block. If something is missing, it explains what and offers a fix.

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
| **SUCCESS** | Done, tests pass, archived. | Review and merge. |
| **NONCRITICAL** | Done, but something does not work (e.g. a test). A `fix-NN-name` change describing the bug was created. Auto-mode continued. | Fix it via the `fix-` change (section 5.3). |
| **BLOCKED** | Architectural problem, auto-mode stopped. | Decide and resolve (section 5.1). |
| **FAILED-CHECK / STOPPED** | The check after a run failed (nothing written, crash, timeout, no progress, push attempt). Auto-mode stopped. | Claude explains the cause and proposes a fix (section 5.2). |
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

Claude explains the cause and proposes a fix. After the fix, `/openspec-auto run`.

### 5.3 Fix changes `fix-…`

Auto-mode does not process them. Either do them with Claude interactively (`/opsx:apply fix-02-profile`), or say "rename fix-02-profile to a numbered change" and the next `/openspec-auto run` processes it.

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

- **Runner:** `openspec-auto.ps1` with the switches `-Init`, `-DryRun`, `-Project <path>`.
- **Skill:** `/openspec-auto` lives in `~/.claude/skills/openspec-auto/SKILL.md`; its source is `claude-skill/` in this repository. `install.ps1` installs it and fills in the runner path. After changing the source or moving the repository, run `install.ps1` again.
- **Report and logs:** `.openspec-auto/` in the project (not in git).
- **Runner start-up messages and fixes:**

| Message | Fix |
|---|---|
| `openspec/auto-mode.json missing` | `/openspec-auto init` |
| `testCommand is not set` | set `testCommand` |
| `is not a git repository` | `git init` and a first commit |
| `HEAD is detached` | `git checkout <branch>` |
| `git user.email is not set` | `git config user.email …` |
| `working tree is not clean` | commit or discard the changes |
| `no active numbered changes` | propose a change or rename one to `NN-name` |
| `change NN-x is blocked` | section 5.1 |
| `not ready …: missing artifacts: …` | add the missing artifact (`/opsx:update`) |
| `not ready …: openspec validate failed: [ERROR] …` | fix according to the error text |
| `not ready …: tasks.md has no tasks` | add tasks `- [ ] 1.1 …` |
| `branch auto/NN-x exists and diverges` (STOPPED in the report) | switch to that branch or delete it |

- **Tool tests** (no API calls): `tests/run-tests.ps1`.
