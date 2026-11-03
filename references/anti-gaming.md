# Anti-gaming

A proof is gamed when it turns green without the claim becoming true. It is rarely deliberate. It happens at the end of a long task, when the goal quietly shifts from "make it work" to "make the check pass". The engine catches some of it mechanically (STALE, MISMATCH, SUSPECT, the contract log). The rest is on you.

## Excuses and what to do instead

| What you are about to say or think | What it really means | Do |
|---|---|---|
| "Should work now" | not run | run the proof |
| "I'm confident" | no evidence | run the proof |
| "It passed earlier" | receipt from another tree | `$P run`, the engine will say STALE anyway |
| "Only a comment changed since" | the tree changed | rerun, it is cheap |
| "The linter passes" | the build was not run | run the build |
| "The subagent said it succeeded" | a claim, not a proof | diff and rerun yourself |
| "The test is flaky" | the proof is not a proof | make it deterministic or report it |
| "Too slow to run the whole suite" | you will report on part | run it, or say which part you ran |
| "The criterion was too strict" | you want to lower it | ask the user, re-freeze with their words |
| "It's just a typo fix" | small task | one criterion, one receipt, still |
| "No way to test this here" | blocked | `$P block` with what is missing |
| "I'll mention it might need checking" | a hedge on a claim | either prove it or say NOT DONE |

## How proofs get gamed (never do these)

1. **Weakening the gate**: editing the command in the contract to something easier, adding `|| true`, `-k` to select only passing tests, `--passWithNoTests`, raising a timeout until the bug hides. (Engine: contract change shows in the log; MISMATCH for old receipts.)
2. **Editing the test to match the bug**: changing an expected value to whatever the code now returns. Only change an expectation when the requirement changed, and say so.
3. **Skipping**: `it.skip`, `@pytest.mark.skip`, `xfail`, commenting out a test, deleting it. (Engine: SUSPECT when only skips ran; the checker reads the diff.)
4. **Mocking the subject**: a test for "sends the email" that mocks the sender and asserts the mock was called proves the call, not the email. Mock the edges (network, clock), never the thing the criterion is about.
5. **Testing the happy path only** when the claim is "handles errors".
6. **Special-casing the test input** in the code (`if user.email == "test@example.com"`).
7. **Disabling the rule** that fails: eslint-disable, `# type: ignore`, `--no-verify`, removing the CI step.
8. **Proving on another tree**: running tests, then making "one last small change". (Engine: STALE.)
9. **The proof that changes what it measures**: a check that writes fixtures or migrates the DB as a side effect. (Engine: SUSPECT when the tree changes during the run.)
10. **Exit 0 on nothing**: the test runner found no tests, the pipeline wrote zero rows, the script hit `command not found` inside a `||`. (Engine: SUSPECT for zero tests, only skips, missing tools; for data, prove a count.)
11. **The screenshot nobody looked at**, or a screenshot of the wrong page, an error page, a loading spinner.
12. **Declaring scope**: quietly moving a hard criterion to "Out of scope" after freezing. Out of scope is written before the work, not during.

## When you notice you did one of these

Undo it, rerun, and say it in the report in one line ("I had skipped test X to unblock; restored, it now fails on Y"). That sentence costs nothing; finding it later costs the user's trust in every other line of the report.
