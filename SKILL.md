---
name: proof-of-done
description: Stops false completion ("hallucinated success"). Before any claim that work is done, fixed, working, passing, deployed or ready, the claim is turned into an acceptance contract written before the code, each criterion is proven by a command or a file whose receipt (exit code, output, working-tree fingerprint) is written by a script, an independent checker re-runs the proofs, and only the computed verdict (DONE, NOT DONE, BLOCKED) may be reported. Use when starting a feature, fix or migration that must really work, before saying done, before a commit, PR, deploy or handover, when a subagent reports success, or when the user doubts a result. Optional Stop hook refuses to end a session on an unproven done. French triggers (preuve avant de dire termine, verifie que c est vraiment fini, ne me dis pas que c est fait sans preuve, criteres d acceptation, fausse completion, il dit que c est fini mais ca ne marche pas, verification avant livraison, prouve-le). Local routing (proves one task's acceptance; for launch readiness of a whole app use production-audit, to design an agent loop use loop-design-check).
argument-hint: "[task or criteria to prove, or: verdict | hook]"
---

# Proof of done

You do not decide that work is done. A script does, from receipts. Your job is to write the contract, produce the proofs, and report the verdict the script computes, word for word.

**Request:** $ARGUMENTS

## The rule

```
NO RECEIPT, NO CLAIM.
A receipt counts only on the code it was taken on.
The verdict is computed, never written by hand.
```

"Done", "fixed", "works", "passes", "ready", "deployed", "all good", a check mark, or any sentence that lets the reader believe one of these, is a claim. So is "should work", which is a claim with an excuse attached. Every claim needs a PROVEN line in the ledger for the current tree, or it is not made.

## The engine

`scripts/proof.py` in this skill's folder (usually `~/.claude/skills/proof-of-done/scripts/proof.py`, or `.claude/skills/proof-of-done/...` in a project). Standard library, Python 3.8+. Set it once per session:

```bash
P="python3 $(ls -d ~/.claude/skills/proof-of-done .claude/skills/proof-of-done 2>/dev/null | head -1)/scripts/proof.py"
```

Everything lives in `.proof/` at the project root: `acceptance.md` (the contract, commit it), `contract.lock` and `contract-log.md` (commit them), `receipts.jsonl` and `artifacts/` (local evidence, git-ignored).

## The five moves

### 1. Contract, before the code

`$P init`, then write `.proof/acceptance.md`. One line per criterion, four fields:

```
- AC1 :: a signed-in user can connect Gmail and sees "Connected" :: e2e :: run: npx playwright test tests/gmail-connect.spec.ts
- AC2 :: an email becomes a task with its subject as title :: integration :: run: pytest tests/test_email_to_task.py -q
- AC3 :: the inbox page shows the new task without reload :: visual :: see: screenshot after converting one email
```

- A criterion states what someone can **observe** (a user, a caller, a file, a row), not what code exists. "Added a handler" is not a criterion.
- The rung is the strength of proof the claim needs. Read [references/proof-ladder.md](references/proof-ladder.md) to pick it: a UI claim needs at least `e2e` or `visual`, a bug fix needs a test that failed before the fix, a deploy needs `runtime` on the deployed target.
- `run:` is the exact command that exits 0 only if the criterion holds. Write it as you will run it. Narrow is fine (one test file), vacuous is not (`true`, `echo ok`, a test with no assertion).
- If the user gave criteria, use their words. If not, derive them from the request, show them in one short block, and go on (do not wait unless a criterion is truly ambiguous). Add an `## Out of scope` list so nobody grades you on what was not asked.
- `$P lint` reads the contract without running anything and flags proofs that could pass while the criterion is false: a command that cannot fail (`true`, `echo`, `|| true`), a grep for a word failure output prints too (`ok`, `success`, `done`), an absence check with no positive control (`! grep ...` alone also passes when the file is missing), `curl` without `-f`, a pipe that hides the test's exit code (`pytest | tee log` without `pipefail`), a number only an eye checks on a `see:` line, a criterion that names work done ("added a retry") instead of an outcome, and a contract where most criteria have no `run:`. Fix what it flags before freezing; `freeze` prints the same warnings. `$P lint --strict` exits 1 on any warning, for use as a criterion or in CI. The lint is lexical and advisory: a warning is a question to answer, not a verdict.
- `$P freeze`. From now on, removing a criterion, lowering a rung or swapping a command for an easier one shows up in `contract-log.md` and needs `--reason` with the user's agreement. Adding criteria is always fine.

For a one-line change, the contract can be one criterion. It still exists.

### 2. Build, proving as you go

Implement normally. After each coherent step, `$P run AC2` (or `$P run --all`) and read what it prints. A FAILED line is information, not an obstacle to route around: read the output, fix the cause, run again. For a bug fix, run the new test **before** the fix and keep that failing receipt in mind: a regression test that never failed proves nothing (red, then green).

For `see:` criteria: produce the evidence (Playwright screenshot, `curl -i` output saved to a file, an exported CSV, a log excerpt), **open it and look at it** (Read the image, read the file), then `$P attach AC3 path/to/shot.png --note "inbox after convert, task visible"`. The file is copied into `.proof/artifacts/`, so it does not disturb other receipts. Attaching a screenshot you did not look at is the same lie as quoting a test you did not run.

### 3. Verdict

```bash
$P run --all      # fresh receipts for every run: criterion, on the final tree
$P verdict        # the ledger and the verdict; exit 0 only if DONE
```

States: `PROVEN` (receipt passes on the current tree), `FAILED`, `PENDING` (no receipt), `STALE` (code changed after the proof), `MISMATCH` (the receipt ran another command than the contract), `SUSPECT` (exit 0 but zero tests ran, only skips, a missing tool, or the proof edited the tree), `BLOCKED`, `WAIVED`. Verdicts: `DONE`, `DONE WITH WAIVERS`, `BLOCKED`, `NOT DONE`.

Any edit after the last run, even a comment, makes receipts STALE. That is the point: rerun last, report right after.

### 4. Independent check

The maker never grades its own work. When the task is more than a small change, touched a UI, a deploy or data, or was done by subagents, launch one checker subagent with the prompt in [references/checker.md](references/checker.md). It re-reads the contract, re-runs the proofs itself, looks at the attached files, reads the diff for scope creep and gate tampering, and returns ACCEPT or REJECT with reasons. A REJECT goes back to move 2. When a subagent tells *you* it succeeded, treat it the same way: `git diff --stat`, run its proof yourself.

### 5. Report

Start with the verdict line exactly as computed, then the receipts:

```
VERDICT: DONE   (or NOT DONE / BLOCKED / DONE WITH WAIVERS)

| Criterion | Proof | Result |
|---|---|---|
| AC1 user connects Gmail, sees "Connected" | npx playwright test tests/gmail-connect.spec.ts | exit 0, 3 passed |
| AC2 email becomes task | pytest tests/test_email_to_task.py -q | exit 0, 5 passed |
| AC3 inbox shows task without reload | .proof/artifacts/AC3-...png (looked at) | task visible at top |

Checker: ACCEPT (or REJECT: ...)
Not proven: none   (or each open criterion, why, and the next action)
Out of scope: ...
```

On NOT DONE, say so first and plainly, then what is proven, what is not, and the smallest next step. A clear NOT DONE is a good report. A DONE that turns out false costs the user a debugging session and their trust.

## Language guard

Before sending any message, scan it. These need a PROVEN receipt on the current tree, or they go:

- done, finished, complete, fixed, resolved, works, working, passes, green, ready, shipped, deployed, live, all good, should work, should be fixed, probably, looks good, ✅, "Perfect!", "Great, that worked"
- "tests pass" when you ran a subset; "build passes" when you ran the linter; "deployed" when you pushed; "fixed" when you changed code and did not reproduce the symptom.

Say what you ran and what it returned: "`pytest tests/test_email_to_task.py`: 5 passed, exit 0" carries itself. When you have not run it: "not verified yet".

The full table of excuses and the ways a proof gets gamed is in [references/anti-gaming.md](references/anti-gaming.md). Read it once per project; the short version: never weaken, skip, mock away, or delete the thing that proves the claim, and never edit a test to match a wrong output.

## Stop hook (optional, per project)

`$P hook --install` adds a Stop hook to `./.claude/settings.local.json` (`--shared` for the committed `settings.json`). In a project that has `.proof/acceptance.md`, when the session tries to end while the verdict is not DONE, the hook sends it back once with the open criteria, unless the last message already says `VERDICT: NOT DONE` or `VERDICT: BLOCKED`. It never loops (it lets the second stop through) and does nothing in projects without a contract. Install it for long or unattended work; tell the user it is there.

## When the proof cannot be run

No browser, no staging access, a missing secret, a paid API: do not substitute a weaker proof silently. `$P block AC4 --reason "no staging credentials"` and report BLOCKED with the exact thing that is missing and the command that would prove it once it is there. `$P waive` exists only for a criterion the user explicitly drops, in their words, quoted in the reason.

## Small tasks

A typo or a one-line config: one criterion, one command, one receipt, one line in the report (`VERDICT: DONE` + the command and its result). The ceremony scales down; the rule does not.
