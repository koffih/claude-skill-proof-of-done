# Proof ladder: what each claim needs

Rungs, weakest to strongest. A criterion's rung is the **lowest rung that can tell a working change from a broken one** for that claim. Pick higher when the claim is about what a person sees or what runs in production.

| Rung | What it is | Proves | Does not prove |
|---|---|---|---|
| `static` | type check, compile, lint, schema validation | the code is well-formed | that it does the right thing |
| `unit` | a test that calls one function or module with real assertions | the logic in isolation | wiring, configuration, the database, the network |
| `integration` | test through real modules and a real store (test DB, local server) | the pieces talk to each other | the UI, the deployed environment |
| `e2e` | a browser or client drives the app like a user (Playwright, Cypress, a CLI run end to end) | the user path works locally | production configuration, secrets, scale |
| `runtime` | the behaviour observed on the real target: `curl` the deployed URL, query the production row, read the live log | it works where it must work | anything not exercised |
| `visual` | a screenshot, recording or rendered file, looked at | what a person will see | behaviour not on screen |
| `manual` | a person did it and reported it | their observation | anything they did not do |

Rungs do not substitute for each other sideways: a passing unit test does not prove a page renders, a screenshot does not prove the data is saved.

## Claim to required proof

| Claim | Minimum rung | Proof that counts | Not enough |
|---|---|---|---|
| "Tests pass" | the suite | the full suite command, exit 0, count of passed > 0 | a subset, an earlier run, "should pass" |
| "Build succeeds" | static | the build command itself, exit 0 | the linter, the dev server starting |
| "Bug fixed" | unit or higher | a test reproducing the symptom: FAILED before the fix, PROVEN after | code changed, error no longer in a log you did not trigger |
| "Feature works" (backend) | integration | request in, observable result out (row, response, file) | the handler exists, unit tests of helpers |
| "Feature works" (UI) | e2e + visual | Playwright clicks through, screenshot looked at, console has no errors | component renders in a unit test |
| "Page looks right" | visual | screenshots at the widths that matter (e.g. 390, 768, 1440), looked at | the CSS compiles |
| "Deployed" / "live" | runtime | `curl -fsS https://.../health` or the changed behaviour on the real URL, new version visible | `git push`, CI green, "deploy started" |
| "Migration done" | runtime | row counts or a query on the migrated store, before and after | the migration file exists, the command printed nothing |
| "Data pipeline works" | runtime | rows written this run with today's timestamp, and a count > 0 | exit 0 (a pipeline that wrote nothing also exits 0) |
| "Job / timer runs" | runtime | its last run time and its output from the scheduler (`systemctl list-timers`, `crontab -l` + log) | the unit file exists |
| "Performance improved" | runtime | the same benchmark before and after, numbers in the receipt | "it feels faster" |
| "Docs updated" | static | the file diff, and the example in it actually run | "README mentions it" |
| "Agent / subagent finished" | the rung of its own claim | `git diff --stat` plus its proof re-run by you | its message saying success |
| "Requirements met" | per criterion | every line of the contract PROVEN | the tests you happened to write |

## Writing good proof commands

- **Exit code carries the verdict.** `grep -q`, `test`, `jq -e`, `curl -fsS`, `pytest`, `npx playwright test` all fail loudly. `echo`, `cat`, `curl` without `-f`, `|| true` and `; exit 0` hide failure.
- **Pipelines hide failure.** `cmd | tail` returns tail's exit code. Use `set -o pipefail; cmd | tail -5`, or let the engine keep the tail for you (it records the last 40 lines anyway).
- **Assert the outcome, not the absence of error.** `curl -fsS $URL | grep -q '"status":"connected"'` beats `curl -fsS $URL`.
- **Count.** For data, prove a number: `psql -tAc "select count(*) from tasks where created_at > now() - interval '10 min'" | grep -qv '^0$'`.
- **One criterion, one command.** If two things must hold, write two criteria; a combined command hides which one broke.
- **Deterministic.** No sleeps that guess, no dependence on yesterday's data. If the proof is flaky, the flakiness is a finding.

## UI proofs with Playwright (the usual pattern)

```ts
// tests/proof/inbox-convert.spec.ts
import { test, expect } from '@playwright/test';
test('email becomes a task', async ({ page }) => {
  const errors: string[] = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  await page.goto('http://localhost:3000/inbox');
  await page.getByRole('button', { name: 'Convert to task' }).first().click();
  await expect(page.getByRole('listitem').filter({ hasText: 'Quarterly report' })).toBeVisible();
  await page.screenshot({ path: 'proof-inbox.png', fullPage: true });
  expect(errors).toEqual([]);
});
```

Contract lines: `run: npx playwright test tests/proof/inbox-convert.spec.ts` (e2e) and `see: proof-inbox.png` attached after you looked at it (visual). Before/after screenshots are worth taking when the claim is "changed the look of X".

No Playwright in the project and no permission to add it: a Chrome DevTools or browser MCP session, then the screenshot attached, is acceptable. No browser at all: BLOCKED for the visual criterion, not a silent downgrade to a unit test.
