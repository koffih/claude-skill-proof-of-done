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
bad()  { fail=$((fail+1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /'; }
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
