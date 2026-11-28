# Memory recovery for unattended (night) runs – plan

Status: plan agreed 2026-11-28 (section 8); steps 2–5 implemented (2–4 on 2026-11-28, 5 next session; tests T43–T47; nested jobs checked by a probe inside Claude Code and in an own window; step 4 with two levels: low = recover and go on, critical 3 GB / 95 % = also wait, then stop), steps 5–8 open. Date: 2026-11-28.
Order: first of the three plans, before `docs/limit-continue-plan.md`. Builds on `docs/memory-pressure-plan.md` (steps 1–4).

## 1. Problem

Goal of the user: auto-mode runs at night without supervision and fails only in exceptional
cases. Today, when memory is short, the batch **stops at once**:

- the start warns below `minFreeMemoryGB` (8 GB) but goes on;
- an out-of-memory error of the worker (LOW-MEMORY) or of the tests → STOPPED, leftovers stashed;
- nothing tries to free memory or to wait, so a stop that one `gradlew --stop` would have avoided
  waits until morning.

A measurement during a real run of a mobile project: the biggest consumers were the Gradle/Kotlin
daemons (`java`) and the emulator (`qemu`), and the **commit charge** was much closer to its limit
than the available memory suggested (pagefile system-managed).
Windows refuses allocations when the commit limit is reached, not when "available" is low, and the
runner measures only available memory.

The plan must work for any project (mobile, web, .NET, …); technology-specific knowledge lives in
the project config and in the skill, not in the runner.

## 2. Layer 1 – generic mechanisms in the runner (every project)

1. **Memory check before every run and before every test command**, not only at the start:
   available memory and commit charge (`Win32_OperatingSystem`: total/free virtual memory).
   Thresholds: `minFreeMemoryGB` (existing) and new `maxCommitPercent` (default 85).
2. **Recovery when below a threshold** (in this order, each step re-measures):
   1. run the project's `memoryCleanupCommands` (layer 2), if any;
   2. stop **leftover processes of earlier runs** (point 3), except `keepProcesses` (point 4);
   3. wait up to `memoryWaitMinutes` (default 10), measuring every 30 s;
   4. still short → STOPPED with a clear message naming the measured values and the top
      consumers (process names only, as the existing warning).
3. **Leftover processes of a run:** processes started during a run (worker, tests and their
   children) that are still alive after the run ended – build daemons, dev servers, watchers,
   simulators. Found without knowing the technology:
   - each worker run and each test command gets its own nested job object inside the runner's
     job (Windows 8+); after it ends, the runner lists the processes still in that job
     (`QueryInformationJobObject`, process id list); daemons that detached from their parent stay
     in the job, so they are found too;
   - processes that existed before the batch started (e.g. an emulator started by the user) are
     never in these jobs and are never touched;
   - they are stopped **only when memory is short** (point 2), not after every run, because the
     next run may reuse them (warm build daemon).
   To check during implementation: nested jobs work under Claude Code's job (`0x1800`) and with
   `-Background`; fallback = snapshot of process ids + start times before the run and a
   parent-chain walk after it.
4. **`keepProcesses`** (project config, wildcards): processes never stopped by the recovery, even
   when a run started them, e.g. `["qemu-system-*", "emulator*", "adb"]` for a mobile project or a
   database container for a web project. The emulator then keeps running in every case:
   `gradlew --stop` stops only Gradle daemons, the emulator and `adb` are separate processes.
5. **One retry after an out-of-memory error** (worker LOW-MEMORY or tests out of memory):
   leftovers stashed as today, recovery (point 2), then the same run or the same tests once more.
   Second out-of-memory → STOPPED as today. Counter per change.
6. **Memory log:** one line per minute during the batch to `<runDir>/memory.csv` (time, available,
   commit, commit limit, top 5 processes by working set: name + MB). Basis for diagnosis and later
   for the dashboard (`docs/dashboard-plan.md`).
7. **Report:** recoveries are listed (`run 4: memory 3.1 GB → ran gradlew --stop, stopped 2
   leftover processes (java 2.9 GB) → 7.8 GB, continued`), also in the notification when the batch
   stops.

## 3. Layer 2 – optional cleanup commands of the project

New config `memoryCleanupCommands` (list, like `testCommand`; empty by default). Examples the skill
can propose:

| Technology | Command |
|---|---|
| Gradle / Kotlin | `gradlew --stop` (Kotlin daemon ends on its own when idle) |
| Maven daemon | `mvnd --stop` |
| .NET | `dotnet build-server shutdown` |
| Bazel | `bazel shutdown` |
| Docker | `docker compose stop` (only containers not needed by the tests) |

Run with a timeout (`testTimeoutMinutes`), output to `<runDir>/cleanup.txt`; a failing command is a
note, not a stop. The commands must not dirty the working tree (checked like the tests).

## 4. Layer 3 – the skill

- **Init / readiness:** detects the technology from files (`gradlew`, `pom.xml` + `.mvn`,
  `*.csproj`, `WORKSPACE`/`MODULE.bazel`, `docker-compose.yml`, `package.json`, Android/iOS
  folders) and proposes `memoryCleanupCommands`, `keepProcesses` and, where useful, memory limits
  in the project (e.g. `org.gradle.jvmargs`, `kotlin.daemon.jvmargs`, `org.gradle.workers.max`,
  `NODE_OPTIONS=--max-old-space-size`). Changes to the project only with the user's ok.
- **Night start checklist:** before starting, shows the top memory consumers (any applications)
  and the commit charge, recommends what to close, and reminds that Claude Code itself can be
  closed after the start (the runner runs on its own, ~2 GB more). It never closes applications.
- **Automatic updates in the checklist:** a driver update during a run can crash everything that
  draws through the graphics card. Seen in a real batch: the GPU vendor's update tool installed a
  new display driver in the middle of a run; the emulator and the terminal with Claude Code
  crashed, the runner (own window) survived. The checklist therefore reminds to
  - switch off automatic driver/software updates of the graphics card vendor (update by hand in
    the daytime),
  - pause Windows Update or set its active hours so it does not restart the PC at night.
  Read-only hints where possible (e.g. Windows Update pause state, a vendor updater process
  running); the skill never changes these settings itself.

## 5. Not planned

- The runner closing the user's applications (risk of losing unsaved work).
- Switching off Claude Code's background-shell reaper (not needed since `-Background`).
- Changing the pagefile (system-managed is fine; the commit check only warns and recovers).

## 6. Steps

1. Spec decisions (open questions), plan updated.
2. Measurement: commit charge, memory log, check before every run/test (tests with
   `OSA_TEST_FREE_MB` and a new test override for commit).
3. Leftover processes: nested job per run/test, list after the end, stop with `keepProcesses`
   (tests: fake worker starts a detached sleeper; a pre-existing process is never touched;
   a kept process survives).
4. Recovery sequence + wait + one retry after out of memory (fake agent LOW-MEMORY mode exists).
5. `memoryCleanupCommands` (tests with a fake cleanup script).
6. Skill: detection + proposals, night checklist (memory, automatic updates); `install.ps1`.
7. Docs (GUIDE, README, appendix).
8. Real check on a project with Gradle + emulator (e.g. a mobile project): recovery with the emulator kept
   running; cost estimate first, needs ok.

Each step needs the user's ok; nothing that touches a running batch.

Status 2026-11-28: steps 1–7 done; step 8 waits for a cost estimate and the user's ok.

## 7. Benefits and risks

Benefits: most memory stops at night become a short pause instead of a stopped batch; the cause
of a real stop is visible (memory log, top consumers); works for any technology, with extra help
where the project defines cleanup commands.

Risks:
- stopping a leftover process the next run needs (e.g. an emulator started by the agent) → only
  when memory is short, `keepProcesses`, listed in the report; the next run can start it again;
- slower next build after stopping build daemons (tens of seconds);
- waiting and the retry make the night longer and cost a little more → `memoryWaitMinutes`, one
  retry per change;
- nested job objects may behave differently under a future Claude Code → fallback (2.3), job line
  already logged at every start;
- a cleanup command with side effects (e.g. stopping a database the tests need) → proposed by the
  skill, confirmed by the user, output logged.

## 8. Decisions (2026-11-28)

1. Order: this plan first, then `docs/limit-continue-plan.md`, then `docs/dashboard-plan.md`
   (its import step before 2026-12-08).
2. Defaults: `maxCommitPercent` 85, `memoryWaitMinutes` 10, one retry per change.
3. Memory log once per minute.
4. Two levels (decided before step 4): *low* (`minFreeMemoryGB` 8 / `maxCommitPercent` 85) = cleanup
   and stop leftovers, then go on; *critical* (`criticalFreeMemoryGB` 3 / `criticalCommitPercent` 95)
   = the same, then wait `memoryWaitMinutes` and stop. Waiting already at the warning level would
   stop runs that pass today (6–10 GB free is normal on a busy PC).
