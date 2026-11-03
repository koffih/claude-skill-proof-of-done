#!/usr/bin/env python3
"""proof-of-done: receipts and verdict for "is this task really done?".

The agent never decides it is done. This script does, from three files kept in
.proof/ at the project root:

  acceptance.md   the contract: one line per acceptance criterion and its proof
  contract.lock   a hash of the contract taken by `freeze`, so a criterion
                  cannot be weakened after the fact without it showing
  receipts.jsonl  one receipt per proof run: command, exit code, output tail,
                  and a fingerprint of the working tree at that moment

A receipt only counts while the working tree still has the fingerprint it was
taken on. Edit one file after the tests ran and every receipt goes STALE.

Commands (run from the project root):
  proof.py init                       create .proof/acceptance.md from the template
  proof.py freeze [--reason TEXT]     lock the contract (again, with a reason)
  proof.py run AC1 [AC2 ...] | --all  run the contract's command for these criteria
  proof.py attach AC3 FILE [--note]   record a file (screenshot, log, export) as proof
  proof.py block AC4 --reason TEXT    mark a criterion blocked on something outside
  proof.py waive AC5 --reason TEXT    waive a criterion (only on the user's word)
  proof.py verdict [--json]           print the ledger and the verdict, exit 0 only if DONE
  proof.py hook                       Stop hook: refuse to end on an unproven "done"
  proof.py hook --install [--shared]  add that hook to ./.claude/settings.local.json

Standard library only. Python 3.8+.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

DIR = ".proof"
CONTRACT = os.path.join(DIR, "acceptance.md")
LOCK = os.path.join(DIR, "contract.lock")
RECEIPTS = os.path.join(DIR, "receipts.jsonl")
LOG = os.path.join(DIR, "contract-log.md")

RUNGS = ["static", "unit", "integration", "e2e", "runtime", "visual", "manual"]
LINE = re.compile(r"^\s*-\s*(AC[\w.-]*)\s*::\s*(.+?)\s*::\s*(\w+)\s*::\s*(run|see)\s*:\s*(.+?)\s*$")

# Output that turns an exit code 0 into a non-proof.
ZERO = re.compile(r"(collected 0 items|no tests ran|\bran 0 tests\b|Tests?:\s+0 total|No tests found|no test files|\b0 (tests|specs|examples) (passed|ran|run)\b|^\s*0 passing\b)", re.I | re.M)
PASSED = re.compile(r"\b[1-9]\d* (passed|passing|tests? passed|ok)\b|\bTests?:.*\b[1-9]\d* passed", re.I)
SKIPPED = re.compile(r"\b[1-9]\d* (skipped|pending|todo)\b", re.I)
BROKEN = re.compile(r"(command not found|ModuleNotFoundError|Cannot find module|ENOENT: no such file)")
SKIP_DIRS = {".git", ".proof", "node_modules", ".venv", "venv", "__pycache__", "dist", "build", ".next", ".cache", "target"}
TAIL = 40
TEMPLATE = """# Acceptance contract

Write it before the code. One line per criterion, four fields separated by ` :: `:

    - <id> :: <what a user or caller can observe> :: <rung> :: run: <command>   (or  see: <what to look at>)

Rungs, weakest to strongest: static, unit, integration, e2e, runtime, visual, manual.
`run:` lines are executed by `proof.py run <id>`, exactly as written here.
`see:` lines need a file attached with `proof.py attach <id> <file>` (screenshot, log, export).

## Criteria

- AC1 :: <replace: the behaviour that must hold> :: unit :: run: <replace: command that exits 0 only if it holds>

## Out of scope

- <what this task deliberately does not do>
"""


def now():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True)
    return r.returncode, r.stdout


def fingerprint():
    """What the working tree looks like now, .proof/ excluded."""
    code, top = git("rev-parse", "--show-toplevel")
    if code == 0:
        _, head = git("rev-parse", "HEAD")
        _, diff = git("diff", "HEAD", "--binary", "--", ".", ":(exclude).proof")
        _, others = git("ls-files", "--others", "--exclude-standard", "-z", "--", ".", ":(exclude).proof")
        h = hashlib.sha256(head + b"\0" + diff)
        for name in sorted(p for p in others.split(b"\0") if p):
            h.update(name)
            try:
                h.update(file_sha(name.decode()).encode())
            except OSError:
                h.update(b"?")
        return "git:" + h.hexdigest()[:16]
    # No git: hash names, sizes and mtimes.
    h = hashlib.sha256()
    for root, dirs, files in os.walk("."):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            p = os.path.join(root, name)
            try:
                st = os.stat(p)
            except OSError:
                continue
            h.update(f"{p}\0{st.st_size}\0{int(st.st_mtime)}\n".encode())
    return "fs:" + h.hexdigest()[:16]


def parse_contract():
    if not os.path.exists(CONTRACT):
        sys.exit(f"no contract: {CONTRACT} is missing. Run `proof.py init` and write the criteria first.")
    items, errors = [], []
    in_criteria = False
    for n, raw in enumerate(open(CONTRACT, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        if line.startswith("## "):
            in_criteria = line.strip().lower() == "## criteria"
            continue
        if not in_criteria or not line.strip().startswith("-"):
            continue
        m = LINE.match(line)
        if not m:
            errors.append(f"line {n}: not `- ID :: criterion :: rung :: run|see: ...`: {line.strip()}")
            continue
        cid, text, rung, kind, proof = m.groups()
        if rung not in RUNGS:
            errors.append(f"line {n}: rung `{rung}` is not one of {', '.join(RUNGS)}")
        if "<replace" in line:
            errors.append(f"line {n}: still a template placeholder")
        items.append({"id": cid, "text": text, "rung": rung, "kind": kind, "proof": proof})
    ids = [i["id"] for i in items]
    for d in sorted({i for i in ids if ids.count(i) > 1}):
        errors.append(f"criterion {d} appears twice")
    if not items:
        errors.append("the contract has no criterion under `## Criteria`")
    return items, errors


def contract_sha():
    return file_sha(CONTRACT) if os.path.exists(CONTRACT) else None


def read_receipts():
    out = []
    if os.path.exists(RECEIPTS):
        for line in open(RECEIPTS, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def write_receipt(rec):
    os.makedirs(DIR, exist_ok=True)
    with open(RECEIPTS, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def lock_state():
    if not os.path.exists(LOCK):
        return "unfrozen"
    try:
        locked = json.load(open(LOCK, encoding="utf-8"))["sha"]
    except (ValueError, KeyError):
        return "unfrozen"
    return "frozen" if locked == contract_sha() else "changed"


def by_id(items, cid):
    for i in items:
        if i["id"] == cid:
            return i
    sys.exit(f"unknown criterion {cid}. Known: {', '.join(i['id'] for i in items)}")


# ---------------------------------------------------------------- commands

def cmd_init(_):
    os.makedirs(DIR, exist_ok=True)
    if os.path.exists(CONTRACT):
        print(f"kept:    {CONTRACT} already exists")
    else:
        open(CONTRACT, "w", encoding="utf-8").write(TEMPLATE)
        print(f"created: {CONTRACT}  (write the criteria, then `proof.py freeze`)")
    gi = os.path.join(DIR, ".gitignore")
    if not os.path.exists(gi):
        open(gi, "w").write("# receipts and evidence are per machine; keep the contract\nreceipts.jsonl\nartifacts/\n")


def cmd_freeze(a):
    items, errors = parse_contract()
    if errors:
        print("cannot freeze, the contract does not parse:")
        for e in errors:
            print("  - " + e)
        return 2
    state = lock_state()
    if state == "frozen":
        print(f"already frozen, {len(items)} criteria")
        return 0
    if state == "changed" and not a.reason:
        print("the contract changed since it was frozen. Re-freeze only with --reason, and only if the user")
        print("approved any criterion that was removed, weakened, or given an easier proof.")
        return 2
    old = None
    if os.path.exists(LOCK):
        old = json.load(open(LOCK, encoding="utf-8"))
    json.dump({"sha": contract_sha(), "at": now(), "items": items}, open(LOCK, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    with open(LOG, "a", encoding="utf-8") as f:
        if old is None:
            f.write(f"- {now()} frozen, {len(items)} criteria\n")
        else:
            before = {i["id"]: i for i in old.get("items", [])}
            after = {i["id"]: i for i in items}
            f.write(f"- {now()} re-frozen: {a.reason}\n")
            for cid in sorted(set(before) | set(after)):
                if cid not in after:
                    f.write(f"  - removed {cid}: {before[cid]['text']}\n")
                elif cid not in before:
                    f.write(f"  - added {cid}: {after[cid]['text']}\n")
                elif before[cid] != after[cid]:
                    f.write(f"  - changed {cid}: {before[cid]['rung']} `{before[cid]['proof']}` -> {after[cid]['rung']} `{after[cid]['proof']}`\n")
    print(f"frozen:  {len(items)} criteria, sha {contract_sha()[:12]}" + (f" (reason logged in {LOG})" if old else ""))
    return 0


def suspect_flags(text):
    """Reasons why an exit code 0 does not prove anything."""
    flags = []
    if ZERO.search(text):
        flags.append("zero tests ran")
    if SKIPPED.search(text) and not PASSED.search(text):
        flags.append("tests were skipped and none passed")
    if BROKEN.search(text):
        flags.append("part of the tooling did not run (command or module not found)")
    return flags


def cmd_run(a):
    items, errors = parse_contract()
    if errors:
        print("the contract does not parse, fix it first:")
        for e in errors:
            print("  - " + e)
        return 2
    targets = [i for i in items if i["kind"] == "run"] if a.all else [by_id(items, c) for c in a.ids]
    if not targets:
        print("nothing to run.")
        return 2
    worst = 0
    for it in targets:
        if it["kind"] != "run":
            print(f"{it['id']}: proof is `see:`, attach a file with `proof.py attach {it['id']} <file>`")
            worst = max(worst, 2)
            continue
        fp_before = fingerprint()
        t0 = time.time()
        p = subprocess.run(it["proof"], shell=True, capture_output=True, timeout=a.timeout)
        out = (p.stdout + p.stderr).decode("utf-8", "replace")
        dur = round(time.time() - t0, 1)
        fp_after = fingerprint()
        tail = "\n".join(out.splitlines()[-TAIL:])
        flags = suspect_flags(out) if p.returncode == 0 else []
        if fp_after != fp_before:
            flags.append("the command changed the working tree while it ran")
        rec = {"id": it["id"], "kind": "run", "cmd": it["proof"], "exit": p.returncode, "seconds": dur,
               "at": now(), "fingerprint": fp_after, "contract": contract_sha(), "output_sha": sha(out.encode()),
               "lines": len(out.splitlines()), "tail": tail, "suspect": flags}
        write_receipt(rec)
        mark = "PASS" if p.returncode == 0 and not flags else ("SUSPECT" if p.returncode == 0 else "FAIL")
        print(f"--- {it['id']}  {mark}  exit {p.returncode}  {dur}s  `{it['proof']}`")
        print("\n".join(tail.splitlines()[-a.show:]))
        for fl in flags:
            print(f"    ! {fl}")
        if mark != "PASS":
            worst = max(worst, 1)
    return worst


def cmd_attach(a):
    items, _ = parse_contract()
    it = by_id(items, a.id)
    if not os.path.isfile(a.file):
        print(f"no such file: {a.file}")
        return 2
    # Evidence is copied out of the working tree, so it never changes the fingerprint it is judged against.
    store = os.path.join(DIR, "artifacts")
    os.makedirs(store, exist_ok=True)
    digest = file_sha(a.file)
    kept = os.path.join(store, f"{it['id']}-{digest[:8]}-{os.path.basename(a.file)}")
    shutil.copyfile(a.file, kept)
    write_receipt({"id": it["id"], "kind": "artifact", "file": kept, "source": os.path.relpath(a.file), "file_sha": digest,
                   "note": a.note or "", "at": now(), "fingerprint": fingerprint(), "contract": contract_sha()})
    print(f"attached: {a.file} to {it['id']} (kept as {kept}). Look at it before trusting it: an attached file is not a looked-at file.")
    return 0


def cmd_mark(a, kind):
    items, _ = parse_contract()
    it = by_id(items, a.id)
    write_receipt({"id": it["id"], "kind": kind, "reason": a.reason, "at": now(), "fingerprint": fingerprint(),
                   "contract": contract_sha()})
    print(f"{kind}: {it['id']} ({a.reason})")
    return 0


def ledger():
    items, errors = parse_contract()
    fp = fingerprint()
    last = {}
    for r in read_receipts():
        last[r["id"]] = r
    rows = []
    for it in items:
        r = last.get(it["id"])
        state, detail = "PENDING", "no receipt"
        if r:
            age = r.get("at", "")
            if r["kind"] == "blocked":
                state, detail = "BLOCKED", r["reason"]
            elif r["kind"] == "waived":
                state, detail = "WAIVED", r["reason"]
            elif r["kind"] == "run" and r.get("cmd") != it["proof"]:
                state, detail = "MISMATCH", f"receipt ran `{r.get('cmd')}`, contract says `{it['proof']}`"
            elif r["kind"] == "artifact" and it["kind"] != "see":
                state, detail = "MISMATCH", "a file was attached but the contract asks for a command"
            elif r["kind"] == "run" and r["exit"] != 0:
                state, detail = "FAILED", f"exit {r['exit']} at {age}"
            elif r["kind"] == "artifact" and (not os.path.isfile(r["file"]) or file_sha(r["file"]) != r["file_sha"]):
                state, detail = "STALE", f"{r['file']} is gone or was altered after it was attached"
            elif r.get("fingerprint") != fp:
                state, detail = "STALE", f"the code changed after this proof ({age})"
            elif r["kind"] == "run" and r.get("suspect"):
                state, detail = "SUSPECT", "; ".join(r["suspect"])
            elif r["kind"] == "artifact":
                state, detail = "PROVEN", f"file {r['file']}" + (f" ({r['note']})" if r.get("note") else "")
            else:
                state, detail = "PROVEN", f"exit 0, {r.get('lines', '?')} lines of output, {age}"
        rows.append({**it, "state": state, "detail": detail})
    return rows, errors, lock_state()


def decide(rows, errors, lock):
    states = [r["state"] for r in rows]
    if errors or lock != "frozen":
        return "NOT DONE"
    if any(s in ("FAILED", "PENDING", "STALE", "MISMATCH", "SUSPECT") for s in states):
        return "NOT DONE"
    if "BLOCKED" in states:
        return "BLOCKED"
    if "WAIVED" in states:
        return "DONE WITH WAIVERS"
    return "DONE"


def cmd_verdict(a):
    rows, errors, lock = ledger()
    verdict = decide(rows, errors, lock)
    if a.json:
        print(json.dumps({"verdict": verdict, "contract": lock, "errors": errors, "fingerprint": fingerprint(),
                          "criteria": rows}, ensure_ascii=False, indent=1))
        return 0 if verdict == "DONE" else 1
    print(f"PROOF LEDGER  tree {fingerprint()}  contract {lock}")
    w = max([len(r["id"]) for r in rows] + [2])
    for r in rows:
        print(f"  {r['id']:<{w}}  {r['state']:<8} {r['rung']:<11} {r['text']}")
        print(f"  {'':<{w}}  {'':<8} {'':<11} -> {r['detail']}")
    for e in errors:
        print(f"  contract error: {e}")
    if lock == "unfrozen":
        print("  contract not frozen: run `proof.py freeze` before claiming anything")
    elif lock == "changed":
        print(f"  contract edited after freeze: see `git diff {CONTRACT}`, re-freeze with --reason once the user agrees")
    seen = [r for r in rows if r["state"] == "PROVEN" and r["kind"] == "see"]
    if seen:
        print("  look at every attached file before reporting: " + ", ".join(r["id"] for r in seen))
    print(f"VERDICT: {verdict}")
    return 0 if verdict == "DONE" else 1


# ---------------------------------------------------------------- Stop hook

HONEST = re.compile(r"VERDICT:\s*(NOT DONE|BLOCKED)", re.I)


def last_assistant_text(path):
    text = ""
    try:
        for line in open(path, encoding="utf-8"):
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            msg = ev.get("message") or {}
            if ev.get("type") == "assistant" or msg.get("role") == "assistant":
                content = msg.get("content")
                parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"] if isinstance(content, list) else [str(content or "")]
                if any(p.strip() for p in parts):
                    text = "\n".join(parts)
    except OSError:
        pass
    return text


def cmd_hook(a):
    if a.install:
        return install_hook(a.shared)
    try:
        data = json.load(sys.stdin)
    except ValueError:
        data = {}
    os.chdir(data.get("cwd") or os.getcwd())
    if not os.path.exists(CONTRACT):
        return 0  # no contract in this project: the hook stays out of the way
    if data.get("stop_hook_active"):
        return 0  # already sent back once: never trap the session in a loop
    try:
        rows, errors, lock = ledger()
    except SystemExit:
        return 0
    verdict = decide(rows, errors, lock)
    if verdict in ("DONE", "DONE WITH WAIVERS"):
        return 0
    said = last_assistant_text(data.get("transcript_path") or "")
    if HONEST.search(said):
        return 0  # the agent already reported the real state
    open_items = [f"{r['id']} {r['state']}: {r['detail']}" for r in rows if r["state"] not in ("PROVEN", "WAIVED")]
    reason = (f"proof-of-done: the ledger says {verdict}, not DONE. "
              + ("Open: " + " | ".join(open_items) + ". " if open_items else "")
              + ("Contract: " + lock + ". " if lock != "frozen" else "")
              + "Either prove the open criteria (`proof.py run --all`, then `proof.py verdict`), "
              "or end your message with the line `VERDICT: NOT DONE` (or `VERDICT: BLOCKED`) and the list of gaps.")
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


def install_hook(shared):
    target = os.path.join(".claude", "settings.json" if shared else "settings.local.json")
    script = os.path.abspath(__file__)
    home = os.path.expanduser("~")
    if script.startswith(home + os.sep):
        script = "$HOME" + script[len(home):]
    command = f'python3 "{script}" hook'
    settings = {}
    if os.path.exists(target):
        try:
            settings = json.load(open(target, encoding="utf-8"))
        except ValueError:
            print(f"{target} is not valid JSON, not touching it.")
            return 2
    stop = settings.setdefault("hooks", {}).setdefault("Stop", [])
    for group in stop:
        for h in group.get("hooks", []):
            if "proof.py" in h.get("command", "") and h["command"].rstrip().endswith(" hook"):
                print(f"already installed in {target}")
                return 0
    stop.append({"hooks": [{"type": "command", "command": command, "timeout": 60}]})
    os.makedirs(".claude", exist_ok=True)
    tmp = target + ".tmp"
    json.dump(settings, open(tmp, "w", encoding="utf-8"), indent=2)
    os.replace(tmp, target)
    print(f"installed: Stop hook in {target}\n           {command}\n           active only where .proof/acceptance.md exists")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="proof.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init")
    p = sub.add_parser("freeze"); p.add_argument("--reason")
    p = sub.add_parser("run"); p.add_argument("ids", nargs="*"); p.add_argument("--all", action="store_true")
    p.add_argument("--timeout", type=int, default=1800); p.add_argument("--show", type=int, default=15)
    p = sub.add_parser("attach"); p.add_argument("id"); p.add_argument("file"); p.add_argument("--note")
    p = sub.add_parser("block"); p.add_argument("id"); p.add_argument("--reason", required=True)
    p = sub.add_parser("waive"); p.add_argument("id"); p.add_argument("--reason", required=True)
    p = sub.add_parser("verdict"); p.add_argument("--json", action="store_true")
    p = sub.add_parser("hook"); p.add_argument("--install", action="store_true"); p.add_argument("--shared", action="store_true")
    a = ap.parse_args()
    if a.cmd == "run" and not a.ids and not a.all:
        ap.error("run needs criterion ids or --all")
    fn = {"init": cmd_init, "freeze": cmd_freeze, "run": cmd_run, "attach": cmd_attach,
          "block": lambda x: cmd_mark(x, "blocked"), "waive": lambda x: cmd_mark(x, "waived"),
          "verdict": cmd_verdict, "hook": cmd_hook}[a.cmd]
    sys.exit(fn(a) or 0)


if __name__ == "__main__":
    main()
