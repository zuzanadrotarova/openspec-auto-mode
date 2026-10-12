# OpenSpec auto-mode

Nástroj bez dozoru implementuje, otestuje a archivuje pripravené OpenSpec zmeny jednu po druhej, v ľubovoľnom projekte.

Podstata: **každý beh agenta je nový proces Claude Code s prázdnym kontextom.** Medzi behmi sa nič neprenáša cez konverzáciu, iba cez súbory (OpenSpec artefakty, kód, git). Veľká zmena sa rozdelí na viac behov, takže kontextové okno sa nikdy nenaplní a agent nezačne halucinovať.

```
openspec-auto.ps1 (deterministický skript)
  pre každú zmenu 01-…, 02-…, …:
    branch auto/NN-nazov (reťazená z predchádzajúcej)
    ┌─ nový proces: claude -p --agent openspec-auto   ← prázdny kontext
    │    implementuje max. tasksPerRun úloh, commitne, skončí
    ├─ skript overí súbory (git status, validate, archív/BLOCKED.md, push)
    └─ ešte nehotovo a je pokrok? → znova, nový proces
  report → .openspec-auto/auto-mode-report.md
```

**Podrobný návod krok za krokom: [NAVOD.md](NAVOD.md).** Úplná špecifikácia je v [ZADANIE.md](ZADANIE.md).

## Požiadavky

- Windows PowerShell 5.1+ (alebo PowerShell 7)
- [Claude Code](https://claude.com/claude-code) (`claude`) a [OpenSpec](https://github.com/Fission-AI/OpenSpec) (`openspec`) v PATH
- git

## Nastavenie v projekte (raz)

```powershell
cd C:\cesta\k\projektu
openspec init                     # ak OpenSpec v projekte ešte nie je
powershell -ExecutionPolicy Bypass -File C:\cesta\k\openspec-auto-mode\openspec-auto.ps1 -Init
```

`-Init` vytvorí `openspec/auto-mode.json`. Uprav ho a commitni:

| Kľúč | Význam | Predvolené |
|---|---|---|
| `testCommand` | príkaz na testy (povinný) | – |
| `allowedCommands` | ďalšie príkazy, ktoré agent smie spúšťať (build, lint…) | `[]` |
| `tasksPerRun` | max. úloh z `tasks.md` na jeden beh (jeden kontext) | 8 |
| `maxRunsPerChange` | max. behov na jednu zmenu | 10 |
| `timeoutMinutes` | časový limit jedného behu | 60 |
| `maxTurns` | max. krokov agenta v jednom behu | 200 |
| `model`, `effort` | model a úroveň uvažovania pre Claude Code | podľa Claude Code |
| `maxBudgetUsdPerRun` | cenový strop jedného behu | bez limitu |

Odporúčané: `.gitattributes` s `* text=auto eol=lf` (inak môžu konverzie koncov riadkov robiť falošne nečistý `git status`).

## Použitie

1. Priprav zmeny interaktívne (`/opsx:propose`) a pomenuj ich s poradím: `01-login`, `02-profil`, … Nemusí to byť celý projekt, stačí dávka; ďalšie zmeny pridáš neskôr a spustíš znova.
2. Commitni ich, pracovný strom musí byť čistý.
3. Spusti (najprv pokojne s `-DryRun`). Pri štarte sa overí, že každá číslovaná zmena má hotový propose: všetky artefakty, aspoň jednu úlohu v `tasks.md` a prejde `openspec validate`. Ak nie, nič sa nespustí a vypíše sa, čo kde chýba.

```powershell
powershell -ExecutionPolicy Bypass -File C:\cesta\k\openspec-auto-mode\openspec-auto.ps1           # v koreni projektu
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -DryRun                              # len kontroly a plán
powershell -ExecutionPolicy Bypass -File ...\openspec-auto.ps1 -Project C:\iny\projekt
```

## Výsledky

| Výsledok | Čo sa stane |
|---|---|
| SUCCESS | zmena implementovaná, testy prechádzajú, archivovaná → ďalšia zmena |
| NONCRITICAL | archivovaná + vznikne `fix-NN-nazov` s popisom chyby (neimplementovaná) → ďalšia zmena |
| BLOCKED | architektonický problém, `openspec/changes/NN-nazov/BLOCKED.md`, nearchivovaná → **stop** |
| FAILED-CHECK | kontrola skriptu neprešla (necommitnuté zmeny, nevalidné špecifikácie, pokus o push, pád, timeout, žiadny pokrok) → **stop** |

Report: `.openspec-auto/auto-mode-report.md`, logy každého behu: `.openspec-auto/runs/<čas>/`. Priečinok je v `.git/info/exclude`, do repozitára sa nedostane.

Nič sa nepushuje ani nemerguje. Branche `auto/NN-…` skontroluješ a zmerguješ sám.

## Po zastavení

Skript si nedrží vlastný stav, opätovné spustenie je ten istý príkaz.

- **BLOCKED:** ostaň na `auto/NN-nazov`, vyrieš problém (napr. `/opsx:update NN-nazov`, inštalácia balíčka, úprava `design.md`), zmaž `BLOCKED.md`, commitni, spusti znova. Kým `BLOCKED.md` existuje, skript odmietne štart.
- **FAILED-CHECK:** pozri report a log behu, daj stav do poriadku (commit alebo revert), spusti znova z aktuálnej branch.
- **`fix-…` zmeny** slučka nespracúva. Implementuj ich interaktívne (`/opsx:apply fix-NN-nazov`), alebo ich premenuj na číslovanú zmenu.

## Bezpečnosť

- Agent beží v režime `dontAsk`: smie iba to, čo je na allowliste (súborové nástroje, `openspec`, lokálny git bez práce s vetvami, `testCommand` a `allowedCommands`).
- Push blokujú tri vrstvy: deny pravidlá, `pre-push` hook aktívny pri `OPENSPEC_AUTO_MODE=1` a kontrola remote refov po každom behu.
- Agent nesmie meniť `.git/`, `.claude/`, `.openspec-auto/` ani `openspec/auto-mode.json`.
- `claude -p` preskakuje dialóg dôvery k priečinku. Spúšťaj ho len v projektoch, ktorým dôveruješ.

## Súbory

| Súbor | Účel |
|---|---|
| `openspec-auto.ps1` | riadiaci skript (slučka, kontroly, report) |
| `worker-prompt.md` | pokyn pre agenta jedného behu |
| `templates/auto-mode.json` | šablóna konfigurácie projektu |
| `tests/run-tests.ps1` | testy logiky slučky s falošným agentom (bez volaní API) |
| `ZADANIE.md` | špecifikácia |

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```
