#!/usr/bin/env python3
"""
cowork-watch.py — Drive Agent Lumen from magpie usage.jsonl for Cowork sessions.

Signal model
------------
- magpie appends one JSON line per completed API call to
  ~/.config/magpie/usage.jsonl  (every stream chunk / tool round-trip).
- A Cowork session is "working" while its cliSessionId keeps producing new rows.
- A Cowork session is "done" when rows stop for IDLE_S and the cowork claude
  process for that session is gone — or immediately when a `result`-type row
  for it lands with a terminal status.
- There is no reliable "attention" (permission-prompt) signal; Cowork's
  permission prompt travels over the Agent SDK stdio pipe, invisible to host.
  So this watcher emits only working / done.

Writes one word per file to ~/.agent-lumen/sessions/cowork-<cliSessionId>:
  working | done
and deletes the file on session end / process death.

Pure stdlib: select.kqueue on the file + a 1 s ticker for the idle check.
"""

import json
import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

USAGE = Path.home() / ".config/magpie/usage.jsonl"
SESS_DIR = Path.home() / ".agent-lumen/sessions"
COWORK_ROOT = (
    Path.home()
    / "Library/Application Support/Claude-3p/local-agent-mode-sessions"
)
LUMEN_LOG = Path.home() / ".agent-lumen/lumen.log"

IDLE_S = 45.0         # one LLM call can take 10–30s+; only call it done after a real lull
CHECK_S = 1.0         # tick granularity
PROC_SCAN_S = 5.0     # how often to rescan cowork processes
DONE_RETIRE_S = 120.0 # after done, keep the green a while before clearing the file

# --- helpers ---------------------------------------------------------------

def log(msg: str) -> None:
    try:
        SESS_DIR.mkdir(parents=True, exist_ok=True)
        with LUMEN_LOG.open("a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} cowork-watch: {msg}\n")
    except Exception:
        pass


def cowork_session_ids() -> set:
    """cliSessionId of every Cowork session dir across all account/org dirs."""
    ids = set()
    try:
        for man in COWORK_ROOT.rglob("local_*.json"):
            try:
                cid = json.loads(man.read_text()).get("cliSessionId")
                if cid:
                    ids.add(cid)
            except Exception:
                continue
    except Exception:
        pass
    return ids


def cowork_pids() -> set:
    """{hash_dir_name} of live cowork claude processes (best effort)."""
    out = set()
    try:
        r = subprocess.run(
            ["pgrep", "-f", "claude-code/"],
            capture_output=True, text=True, timeout=3,
        )
        for pid in r.stdout.split():
            pid = pid.strip()
            if not pid.isdigit():
                continue
            try:
                env = subprocess.run(
                    ["ps", "eww", "-p", pid, "-o", "command="],
                    capture_output=True, text=True, timeout=3,
                ).stdout
                if "CLAUDE_CODE_IS_COWORK" not in env:
                    continue
                cfg = ""
                for tok in env.split():
                    if tok.startswith("CLAUDE_CONFIG_DIR="):
                        cfg = tok.split("=", 1)[1]
                        break
                # cfg is a symlink …/claude-hostloop-plugins/<tmp> → real …/<hash>/.claude
                real = os.path.realpath(cfg) if cfg else ""
                h = os.path.basename(os.path.dirname(real.rstrip("/"))) if real else ""
                if h:
                    out.add(h)
            except Exception:
                continue
    except Exception:
        pass
    return out


_HASH_CACHE = {}

def session_hash(sid: str) -> str:
    """cliSessionId -> owning cowork hash dir name ('57a98445' etc). Cached."""
    if sid in _HASH_CACHE:
        return _HASH_CACHE[sid]
    h = ""
    for man in COWORK_ROOT.rglob("local_*.json"):
        try:
            d = json.loads(man.read_text())
            if d.get("cliSessionId") == sid:
                base = man.stem                      # local_57a98445-7ccb-...
                h = base.split("-", 1)[0].replace("local_", "")
                break
        except Exception:
            continue
    _HASH_CACHE[sid] = h
    return h


def write_state(sid: str, word: str) -> None:
    p = SESS_DIR / f"cowork-{sid}"
    try:
        if word == "end":
            p.unlink(missing_ok=True)
        else:
            p.write_text(word)
    except Exception:
        pass


# --- main ------------------------------------------------------------------

def main() -> None:
    SESS_DIR.mkdir(parents=True, exist_ok=True)
    cowork_ids = cowork_session_ids()
    log(f"start; {len(cowork_ids)} cowork session ids known")

    # per-session state: last activity ts, current light state
    active = {}          # sid -> last_ts
    state = {}           # sid -> 'working'|'done'

    fd = os.open(USAGE, os.O_RDONLY)
    os.lseek(fd, 0, os.SEEK_END)   # only care about new rows

    kq = select.kqueue()
    kev = select.kevent(
        fd,
        filter=select.KQ_FILTER_VNODE,
        flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
        fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND | select.KQ_NOTE_DELETE,
    )

    last_proc_scan = 0.0
    cowork_procs = {}

    running = True
    def stop(*_):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while running:
        # 1) drain new rows
        now = time.time()
        events = kq.control([kev], 1, CHECK_S)
        if events:
            try:
                data = os.read(fd, 1 << 20)
            except OSError:
                data = b""
            for line in data.decode("utf-8", "replace").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                # a 'result'-type row in audit terms is a completed turn
                rtype = row.get("type")
                sid = row.get("session") or row.get("native_session")
                if not sid:
                    continue
                if sid not in cowork_ids and now - last_proc_scan > 2:
                    cowork_ids |= cowork_session_ids()
                if sid in cowork_ids:
                    active[sid] = now
                    if state.get(sid) != "working":
                        state[sid] = "working"
                        write_state(sid, "working")
                        log(f"working {sid[:8]}")

        # 2) idle → done ; dead process → done + clear
        if now - last_proc_scan >= PROC_SCAN_S:
            last_proc_scan = now
            cowork_procs = cowork_pids()
            cowork_ids |= cowork_session_ids()

        for sid in list(active):
            last = active[sid]
            alive = session_hash(sid) in cowork_procs
            if alive:
                # process up: stay working until a real lull — don't drop to done
                # just because one LLM call takes >8s between usage rows.
                if now - last < IDLE_S and state.get(sid) != "working":
                    state[sid] = "working"
                    write_state(sid, "working")
                elif now - last >= IDLE_S and state.get(sid) != "done":
                    state[sid] = "done"
                    write_state(sid, "done")
                    log(f"done {sid[:8]} (idle {now-last:.0f}s)")
            else:
                # process gone → done. A fresh working row within the next few
                # seconds can still flip it back (new turn already spawned).
                if state.get(sid) != "done":
                    state[sid] = "done"
                    write_state(sid, "done")
                    log(f"done+exit {sid[:8]}")
                if now - last > DONE_RETIRE_S:
                    write_state(sid, "end")
                    del active[sid]
                    state.pop(sid, None)
                    log(f"cleared {sid[:8]}")

    # shutdown: mark everything done
    for sid in list(state):
        write_state(sid, "done")
    log("stopped")


if __name__ == "__main__":
    main()
