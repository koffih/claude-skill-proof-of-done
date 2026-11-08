#!/usr/bin/env bash
# Self-test of scripts/proof.py. Exits 0 only if every case behaves as stated.
#   bash tests/run.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
P="python3 $HERE/scripts/proof.py"
W="$(mktemp -d)"
trap 'rm -rf "$W" "${S:-}"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok    $1"; }
bad()  { fail=$((fail+1)); echo "FAIL  $1"; if [ -n "${2:-}" ]; then echo "$2" | sed 's/^/      /'; fi; }
state(){ $P verdict --json | python3 -c "import json,sys;d=json.load(sys.stdin);print({c['id']:c['state'] for c in d['criteria']}.get('$1'))"; }
verdict(){ $P verdict --json | python3 -c "import json,sys;print(json.load(sys.stdin)['verdict'])"; }
expect(){ # label, actual, wanted
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted [$3], got [$2]"; fi; }

cd "$W"
git init -q . && git config user.email t@t && git config user.name t
echo 'print("hi")' > app.py && git add . && git commit -qm init

$P init >/dev/null
cat > .proof/acceptance.md <<'EOF'
# Acceptance contract
## Criteria
- AC1 :: app prints hi :: unit :: run: python3 app.py | grep -q hi
- AC2 :: home page renders :: visual :: see: screenshot of the home page
## Out of scope
- nothing
EOF

expect "unfrozen contract is NOT DONE" "$(verdict)" "NOT DONE"
expect "no receipt is PENDING" "$(state AC1)" "PENDING"
$P freeze >/dev/null
$P run AC1 >/dev/null; expect "passing command is PROVEN" "$(state AC1)" "PROVEN"
expect "see: criterion without file stays PENDING" "$(state AC2)" "PENDING"
expect "one criterion open means NOT DONE" "$(verdict)" "NOT DONE"

S="$(mktemp -d)"; echo png > "$S/shot.png"
$P attach AC2 "$S/shot.png" --note home >/dev/null
expect "attached file proves a see: criterion" "$(state AC2)" "PROVEN"
expect "attaching evidence does not stale other proofs" "$(state AC1)" "PROVEN"
echo notes > notes.txt
expect "a new file in the project makes a run STALE" "$(state AC1)" "STALE"
rm notes.txt
expect "everything proven on the current tree is DONE" "$(verdict)" "DONE"
$P verdict >/dev/null; expect "verdict exits 0 when DONE" "$?" "0"

echo 'print("bye")' > app.py
expect "editing code after proof makes it STALE" "$(state AC1)" "STALE"
expect "code edits stale screenshots too" "$(state AC2)" "STALE"
$P run AC1 >/dev/null; expect "a failing command is FAILED" "$(state AC1)" "FAILED"
$P verdict >/dev/null; expect "verdict exits 1 when not DONE" "$?" "1"
echo 'print("hi")' > app.py; $P run AC1 >/dev/null
expect "fixed and rerun is PROVEN again" "$(state AC1)" "PROVEN"
expect "code restored byte for byte makes the screenshot fresh again" "$(state AC2)" "PROVEN"
f="$(ls .proof/artifacts/AC2-* | head -1)"; echo tampered >> "$f"
$P attach AC2 "$S/shot.png" >/dev/null; $P run AC1 >/dev/null
echo tampered >> "$(ls -t .proof/artifacts/AC2-* | head -1)"
expect "a tampered evidence copy is STALE" "$(state AC2)" "STALE"
rm -f .proof/artifacts/*; $P attach AC2 "$S/shot.png" >/dev/null

# weakening the proof after the fact
sed -i 's/run: python3 app.py | grep -q hi/run: true/' .proof/acceptance.md
expect "edited contract is NOT DONE" "$(verdict)" "NOT DONE"
expect "old receipt for a changed command is MISMATCH" "$(state AC1)" "MISMATCH"
$P freeze >/dev/null 2>&1; expect "re-freeze without a reason is refused" "$?" "2"
$P freeze --reason "user agreed" >/dev/null
grep -q "changed AC1" .proof/contract-log.md && ok "the weakening is written to the contract log" || bad "contract log misses the change"
$P run AC1 >/dev/null; expect "rerun under the new contract is PROVEN" "$(state AC1)" "PROVEN"

# exit 0 that proves nothing
sed -i 's/run: true/run: echo "collected 0 items"/' .proof/acceptance.md; $P freeze --reason t >/dev/null
$P run AC1 >/dev/null; expect "zero tests with exit 0 is SUSPECT" "$(state AC1)" "SUSPECT"
sed -i 's/run: echo "collected 0 items"/run: echo "3 skipped"/' .proof/acceptance.md; $P freeze --reason t >/dev/null
$P run AC1 >/dev/null; expect "only skipped tests is SUSPECT" "$(state AC1)" "SUSPECT"
sed -i 's/run: echo "3 skipped"/run: echo "34 passed, 2 skipped"/' .proof/acceptance.md; $P freeze --reason t >/dev/null
$P run AC1 >/dev/null; expect "passed plus skipped is PROVEN" "$(state AC1)" "PROVEN"
sed -i 's/run: echo "34 passed, 2 skipped"/run: echo "34 passed, 0 skipped"/' .proof/acceptance.md; $P freeze --reason t >/dev/null
$P run AC1 >/dev/null; expect "\"0 skipped\" is not suspect" "$(state AC1)" "PROVEN"
sed -i 's/run: echo "34 passed, 0 skipped"/run: echo x > side.txt/' .proof/acceptance.md; $P freeze --reason t >/dev/null
$P run AC1 >/dev/null; expect "a proof that edits the tree is SUSPECT" "$(state AC1)" "SUSPECT"
rm -f side.txt
sed -i 's/run: echo x > side.txt/run: python3 app.py | grep -q hi/' .proof/acceptance.md; $P freeze --reason t >/dev/null
$P attach AC2 "$S/shot.png" >/dev/null; $P run AC1 >/dev/null
expect "back to DONE" "$(verdict)" "DONE"

# block and waive
$P block AC2 --reason "staging is down" >/dev/null
expect "blocked criterion gives BLOCKED" "$(verdict)" "BLOCKED"
$P waive AC2 --reason "user: skip the screenshot" >/dev/null
expect "waived criterion gives DONE WITH WAIVERS" "$(verdict)" "DONE WITH WAIVERS"
$P attach AC2 "$S/shot.png" >/dev/null; $P run AC1 >/dev/null

# Stop hook
T="$S/transcript.jsonl"
hook(){ printf '%s' "$1" | $P hook; }
echo 'print("bye")' > app.py
out="$(hook "{\"cwd\":\"$W\",\"stop_hook_active\":false,\"transcript_path\":\"$T\"}")"
echo "$out" | grep -q '"decision": "block"' && ok "hook blocks a stop on an unproven tree" || bad "hook did not block" "$out"
echo "$out" | grep -q "AC1 STALE" && ok "hook names the open criterion" || bad "hook reason misses AC1" "$out"
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Gaps listed.\nVERDICT: NOT DONE"}]}}' > "$T"
out="$(hook "{\"cwd\":\"$W\",\"stop_hook_active\":false,\"transcript_path\":\"$T\"}")"
expect "hook lets an honest NOT DONE through" "$out" ""
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All done!"}]}}' > "$T"
out="$(hook "{\"cwd\":\"$W\",\"stop_hook_active\":true,\"transcript_path\":\"$T\"}")"
expect "hook never blocks twice in a row" "$out" ""
echo 'print("hi")' > app.py; $P run AC1 >/dev/null
out="$(hook "{\"cwd\":\"$W\",\"stop_hook_active\":false,\"transcript_path\":\"$T\"}")"
expect "hook stays silent when DONE" "$out" ""
E="$(mktemp -d)"
out="$(printf '{"cwd":"%s"}' "$E" | $P hook)"; expect "hook is silent where there is no contract" "$out" ""
(cd "$E" && $P hook --install >/dev/null && $P hook --install | grep -q already) && ok "hook install is idempotent" || bad "hook install not idempotent"
python3 -c "import json;d=json.load(open('$E/.claude/settings.local.json'));assert len(d['hooks']['Stop'])==1" && ok "hook install writes valid settings" || bad "settings broken"
rm -rf "$E"

# lint: weak proofs are flagged, and nothing is ever executed
L="$(mktemp -d)"; cd "$L"
$P init >/dev/null
cat > .proof/acceptance.md <<'EOF'
# c
## Criteria
- AC1 :: the report lists every school :: unit :: run: true
- AC2 :: the export has rows :: unit :: run: pytest tests/test_export.py || true
- AC3 :: the job logs success :: runtime :: run: journalctl -u job | grep -q success
- AC4 :: no secret is left in the bundle :: static :: run: ! grep -q API_KEY dist/app.js
- AC5 :: the API answers :: runtime :: run: curl -s https://example.com/api/health
- AC6 :: the table shows 120 schools :: visual :: see: screenshot of the table
- AC7 :: added a retry to the importer :: unit :: run: pytest tests/test_import.py -q
- AC8 :: ajouter le bouton de partage :: visual :: see: capture de la page
- AC9 :: nothing is ever run by lint :: unit :: run: touch created-by-lint.txt
- AC10 :: no TODO is left in the app :: static :: run: cd app && ! grep -q TODO main.py
EOF
out="$($P lint)"; code=$?
for pair in AC10:absence-without-control AC1:cannot-fail AC2:cannot-fail AC3:weak-match AC4:absence-without-control AC5:curl-no-fail \
            AC6:unmeasured-number AC7:activity-not-outcome AC8:activity-not-outcome; do
  id="${pair%%:*}"; rule="${pair#*:}"
  echo "$out" | grep -qE "^  $id +$rule " && ok "lint flags $rule on $id" || bad "lint missed $rule on $id" "$out"
done
if echo "$out" | grep -qE "^  AC9 "; then bad "lint leaves a sound run: line alone" "$out"; else ok "lint leaves a sound run: line alone"; fi
if [ -e created-by-lint.txt ]; then bad "lint never executes a command"; else ok "lint never executes a command"; fi
expect "plain lint exits 0 with warnings" "$code" "0"
$P lint --strict >/dev/null; expect "lint --strict fails on a warning" "$?" "1"
$P lint --json | python3 -c "import json,sys;d=json.load(sys.stdin);assert len(d['warnings'])>=8" && ok "lint --json lists the warnings" || bad "lint --json broken"
printf '# c\n## Criteria\n- AC1 :: x :: visual :: see: a\n- AC2 :: y :: visual :: see: b\n- AC3 :: z :: unit :: run: pytest -q\n' > .proof/acceptance.md
$P lint | grep -q "mostly-manual" && ok "lint flags a mostly manual contract" || bad "lint missed mostly-manual"
cat > .proof/acceptance.md <<'EOF'
# c
## Criteria
- AC1 :: the export holds one row per school :: integration :: run: pytest tests/test_export.py -q
- AC2 :: no secret is left in the bundle :: static :: run: test -s dist/app.js && ! grep -q API_KEY dist/app.js
- AC3 :: the API answers with version 1.4.0 :: runtime :: run: curl -fsS https://example.com/api/health | grep -q '"version":"1.4.0"'
- AC4 :: the inbox at 390 px shows the new task :: visual :: see: screenshot
- AC5 :: support tickets appear in the inbox :: e2e :: run: npx playwright test inbox.spec.ts
- AC6 :: updates are saved :: unit :: run: pytest -q
- AC7 :: Review comments appear under the post :: e2e :: run: npx playwright test review.spec.ts
- AC8 :: Handled errors show a message :: unit :: run: npm test
- AC9 :: la page d'accueil passe le contraste WCAG 2.1 :: visual :: see: capture
- AC10 :: l'utilisateur voit la tâche :: e2e :: run: npx playwright test tache.spec.ts
- AC11 :: the API answers HTTP 200 on version 1.4 :: runtime :: run: curl -fsS https://example.com/api/health
- AC12 :: the page renders on iOS 17 Safari and Chrome 120 :: visual :: see: two screenshots
- AC13 :: the step 2 form shows the address on Node 20 :: visual :: see: capture
- AC14 :: l'étape 3 affiche le récapitulatif sur iPhone 15 :: visual :: see: capture
EOF
expect "a sound contract lints clean" "$($P lint)" "LINT OK"
$P lint --strict >/dev/null; expect "lint --strict passes a clean contract" "$?" "0"
printf '# c\n## Criteria\n- AC1 :: the page loads :: runtime :: run: curl -s http://localhost:3000\n' > .proof/acceptance.md
out="$($P freeze)"; code=$?
if [ "$code" = 0 ] && echo "$out" | grep -q "^frozen:" && echo "$out" | grep -q "curl-no-fail"; then
  ok "freeze shows lint warnings and still freezes"; else bad "freeze shows lint warnings and still freezes" "$out"; fi
cd /; rm -rf "$L"

# without git
N="$(mktemp -d)"; cd "$N"
echo a > f.txt; $P init >/dev/null
printf '# c\n## Criteria\n- AC1 :: file has a :: unit :: run: grep -q a f.txt\n' > .proof/acceptance.md
$P freeze >/dev/null; $P run AC1 >/dev/null
expect "outside git a passing run is PROVEN" "$(state AC1)" "PROVEN"
sleep 1; echo b >> f.txt
expect "outside git an edit makes it STALE" "$(state AC1)" "STALE"
printf '# c\n## Criteria\n- AC1 :: x :: fast :: run: true\n- AC1 :: y :: unit :: run: true\n' > .proof/acceptance.md
$P freeze >/dev/null 2>&1; expect "a bad rung and a duplicate id refuse to freeze" "$?" "2"
cd /; rm -rf "$N"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
