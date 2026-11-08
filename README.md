# proof-of-done

A [Claude Code](https://claude.com/claude-code) skill against **false completion**: the agent says "Done!", the tests were never run, the page never opened, the deploy never landed.

Asking an agent to be honest does not fix this. Taking the decision away from it does. With this skill, the agent never decides it is done: a script does, from **receipts**.

```
NO RECEIPT, NO CLAIM.
A receipt counts only on the code it was taken on.
The verdict is computed, never written by hand.
```

## How it works

1. **Contract before code.** `.proof/acceptance.md` lists what someone must be able to observe, each with the strength of proof it needs (static, unit, integration, e2e, runtime, visual, manual) and the exact command that proves it. `lint` flags proofs that could pass while the criterion is false (a command that cannot fail, a grep for `ok`, an absence check with no positive control, `curl` without `-f`, a criterion that names work done instead of an outcome), without running anything. `freeze` locks it: weakening a criterion later is logged and needs the user's agreement.
2. **Receipts, not prose.** `proof.py run AC2` runs the contract's own command and writes a receipt: exit code, output tail, and a fingerprint of the working tree. Screenshots and other evidence are attached as files and copied aside.
3. **Freshness is mechanical.** Edit one line after the tests ran, and every receipt goes `STALE`. Run a different command than the contract says: `MISMATCH`. Exit 0 with zero tests, only skips, a missing tool, or a proof that edits the tree: `SUSPECT`.
4. **Maker and checker are separate.** An independent subagent re-reads the contract, re-runs the proofs, looks at the screenshots and reads the diff for skipped tests, loosened assertions or scope creep. It answers ACCEPT or REJECT.
5. **The verdict is reported as computed**: `DONE`, `DONE WITH WAIVERS`, `BLOCKED` or `NOT DONE`, with a table of receipts. A clear NOT DONE is a good report.
6. **Optional Stop hook.** In a project with a contract, the session cannot end on an unproven "done": it is sent back once with the open criteria, unless it already reported `VERDICT: NOT DONE` or `BLOCKED`. It never loops.

```
PROOF LEDGER  tree git:3f9c1a0e7b2d4c11  contract frozen
  AC1  PROVEN   e2e         a signed-in user connects Gmail and sees "Connected"
                            -> exit 0, 14 lines of output, 2026-11-03T17:40:12-05:00
  AC2  STALE    integration an email becomes one task with its subject as title
                            -> the code changed after this proof (2026-11-03T17:31:55-05:00)
  AC3  SUSPECT  unit        the emoji subject bug is fixed
                            -> zero tests ran
VERDICT: NOT DONE
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/koffih/claude-skill-proof-of-done/main/install.sh | bash
```

Options after `bash -s --`: `--project` (into `./.claude/skills`), `--uninstall`. Running it again updates the skill. Or through the catalog: `curl -fsSL https://raw.githubusercontent.com/koffih/claude-skills/main/install.sh | bash -s -- proof-of-done`.

Requires Python 3.8+ (standard library only) and git for tree fingerprints (works without git, with a coarser fingerprint).

## Use

The skill triggers on its own before claims of completion, or explicitly:

```
/proof-of-done add "convert email to task" to the inbox
/proof-of-done verdict
/proof-of-done hook
```

The engine, by hand:

```bash
P="python3 ~/.claude/skills/proof-of-done/scripts/proof.py"
$P init                     # write .proof/acceptance.md
$P lint                     # flag weak proofs (runs nothing)
$P freeze                   # lock the contract
$P run --all                # fresh receipts
$P attach AC5 shot.png --note "inbox at 390px"
$P verdict                  # exit 0 only if DONE
$P hook --install           # Stop hook in ./.claude/settings.local.json
```

Contract line format:

```
- AC2 :: an email becomes one task with its subject as title :: integration :: run: pytest tests/test_email_to_task.py -q
- AC5 :: the inbox after converting one email :: visual :: see: screenshot, task visible at the top
```

A full example is in [`assets/acceptance.example.md`](assets/acceptance.example.md). What each kind of claim needs as proof is in [`references/proof-ladder.md`](references/proof-ladder.md).

## Files

| Path | What |
|---|---|
| `SKILL.md` | the method: contract, prove, verdict, independent check, report, language guard |
| `scripts/proof.py` | the engine: contract parsing, receipts, fingerprints, verdict, Stop hook |
| `references/proof-ladder.md` | claim to required proof, writing proof commands, Playwright pattern |
| `references/checker.md` | the prompt for the independent checker subagent |
| `references/anti-gaming.md` | excuses, and twelve ways a proof gets gamed |
| `assets/acceptance.example.md` | a complete contract for a real-looking feature |
| `tests/run.sh` | the engine's own proof: `bash tests/run.sh` |

## Where the ideas come from

This skill merges and extends patterns from: `verification-before-completion` (OpenAgentsControl), `verification-loop` (everything-claude-code), `acceptance-orchestrator` (popey/claude-code-skills), the delivery reviewer of levnikolaevich/claude-code-skills, [loop-harness](https://github.com/breim/loop-harness) (maker/checker split) and `verification-mastery` (claude-code-maestro), and from Anthropic's advice to give the agent a check that returns pass or fail. What it adds: receipts written by a script instead of claims written by the model, freshness bound to the working tree, a frozen contract whose weakening is logged, detection of exit codes that prove nothing, and a Stop hook. No text was copied from these projects.

## License

MIT
