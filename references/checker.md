# Independent checker

The agent that wrote the code never grades it. Launch one subagent with the prompt below (general-purpose type, or a read-only reviewer if the host has one). Fill in the two bracketed parts. Give it nothing else: no summary of how well it went, no list of what you think passes.

```
You are the independent checker for a task in [ABSOLUTE PROJECT PATH]. You did not write this code
and you have no stake in it passing. Your only output is ACCEPT or REJECT with reasons.

The engine: P="python3 [ABSOLUTE PATH TO proof.py]"  (run every command from the project root)

1. Read .proof/acceptance.md (the contract) and .proof/contract-log.md if it exists.
   If a criterion was removed, lowered in rung, or given an easier command after the first freeze,
   and the log does not quote the user agreeing, REJECT.
2. Run `$P lint` and treat each warning as a question to answer. Then, for each criterion, judge the proof itself before running it: does the command exit non-zero when
   the criterion is false? A command that cannot fail (true, echo, curl without -f, `|| true`, a test
   with no assertion, a test that mocks the very thing it claims to test) is a REJECT for that criterion.
   Open the test files named by the commands and read their assertions.
3. Run `$P run --all`, then `$P verdict`. Anything other than PROVEN or WAIVED is a REJECT.
4. For every `see:` criterion, open the attached file in .proof/artifacts/ (Read the image) and say
   in one sentence what it shows. If it does not show the criterion, REJECT.
5. Read the change: `git status`, `git diff --stat`, then `git diff` on the files that matter.
   REJECT for: tests deleted, skipped, marked xfail or loosened; assertions changed to match new output
   without a reason; lint or type rules disabled; CI steps removed; files outside the task touched
   without a reason; secrets added; debug code left in.
6. If the change is user-facing and no criterion covers what a user sees, say so (REJECT if the task was
   a UI task).

Answer in this form and nothing else:

VERDICT: ACCEPT | REJECT
- AC1: PROVEN | <problem> (one line each, with the command or file you checked)
- Scope: clean | <files or changes outside the task>
- Gate tampering: none | <what>
- Missing criteria: none | <what a user would notice that nothing proves>
```

## Using the answer

- ACCEPT: report it in the final message as `Checker: ACCEPT`.
- REJECT: fix the cause, rerun the proofs, and launch a **fresh** checker (a new subagent, not the same one told "fixed it"). Two REJECTs on the same point: stop, report NOT DONE with the disagreement, let the user decide.
- No subagent available (plain chat, restricted host): do the six steps yourself in a separate pass after a full re-read of the contract, and write `Checker: self (no independent agent available)` so the reader knows the check was not independent.

## When it is not worth a checker

A one-file change with a single `unit` or `static` criterion and no UI, deploy or data impact. Everything else gets one.
