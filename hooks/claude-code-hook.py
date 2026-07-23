#!/usr/bin/env python3
"""agent-notify hook for Claude Code.

Posts a banner when a turn finishes or Claude needs your attention, and
dismisses that chat's banner the moment you follow up in it. Wire it via
Claude Code hooks (install.md does this for you):

  UserPromptSubmit -> python3 ~/.agent-notify/hook.py UserPromptSubmit
  Stop             -> python3 ~/.agent-notify/hook.py Stop
  Notification     -> python3 ~/.agent-notify/hook.py Notification

Privacy: no network access. The script talks only to the local agent-notify
daemon over a unix socket, and keeps per-session last-prompt files under
~/.agent-notify/prompts/ so the Stop banner can show what you asked.
If the daemon is not running, everything is a silent no-op.
"""

import json
import os
import re
import socket
import subprocess
import sys
import time
from datetime import datetime

SOCKET_PATH = os.environ.get(
    "AGENT_NOTIFY_SOCKET", os.path.expanduser("~/.agent-notify.sock")
)
PROMPTS_DIR = os.path.expanduser("~/.agent-notify/prompts")
EXCERPT_LEN = 75


def notifyd(request):
    """Send one command to the daemon. False when it isn't reachable."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect(SOCKET_PATH)
        s.sendall((json.dumps(request) + "\n").encode())
        reply = s.recv(4096)
        s.close()
        return json.loads(reply).get("ok", False)
    except Exception:
        return False


def excerpt(text):
    """Collapse whitespace/newlines and truncate — keeps banners at ~2 lines."""
    flat = " ".join((text or "").split())
    cut = flat[:EXCERPT_LEN].strip()
    return cut + "..." if len(flat) > EXCERPT_LEN else cut


def chat_group(transcript_path, session_id):
    """Stable notification group for a chat: the uuid of its FIRST user
    record. A resumed chat (--resume) gets a NEW session_id, so keying by
    session_id would orphan the previous banner on every resume; the
    transcript copies history verbatim, so this uuid survives forks."""
    if not transcript_path or not os.path.exists(transcript_path):
        return session_id or "unknown"
    result = subprocess.run(
        ["grep", "-m", "1", '"type":"user"', transcript_path],
        capture_output=True, text=True, check=False, timeout=5,
    )
    try:
        return json.loads(result.stdout)["uuid"]
    except Exception:
        return session_id or "unknown"


def chat_title(transcript_path):
    """Chat name set via /rename — the last custom-title record, EXCEPT a
    name merely inherited through /clear. Both /clear and --resume copy the
    old title to line 1 of the fresh file; a resumed file also carries old
    history (its first user record predates the file), while a cleared one
    starts truly fresh — there the inherited name no longer applies.
    Renaming after a clear writes a new value and wins."""
    if not transcript_path or not os.path.exists(transcript_path):
        return None
    titles = []  # (line_number, value)
    result = subprocess.run(
        ["grep", "-n", '"customTitle"', transcript_path],
        capture_output=True, text=True, check=False, timeout=5,
    )
    for line in result.stdout.splitlines():
        lineno, _, payload = line.partition(":")
        try:
            record = json.loads(payload)
            if record.get("type") == "custom-title":
                titles.append((int(lineno), record["customTitle"]))
        except Exception:
            continue
    if not titles:
        return None
    effective = titles[-1][1]

    first_user = subprocess.run(
        ["grep", "-n", "-m", "1", '"type":"user"', transcript_path],
        capture_output=True, text=True, check=False, timeout=5,
    ).stdout
    user_lineno, _, user_payload = first_user.partition(":")
    try:
        user_record = json.loads(user_payload)
        user_line = int(user_lineno)
    except Exception:
        return effective  # no user record yet — keep the title

    inherited = [v for n, v in titles if n < user_line]
    if not inherited or effective != inherited[-1]:
        return effective  # named in this session (or renamed post-clear)

    try:
        ts = datetime.fromisoformat(
            user_record["timestamp"].replace("Z", "+00:00")
        ).timestamp()
        if abs(ts - os.stat(transcript_path).st_birthtime) < 180:
            return None  # fresh start (/clear): inherited name dropped
    except Exception:
        pass
    return effective


def worktree_parts(cwd):
    """(repo, worktree) — worktree is None on the main checkout or outside git."""
    if not cwd:
        return None, None
    result = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--path-format=absolute",
         "--git-common-dir", "--show-toplevel"],
        capture_output=True, text=True, check=False, timeout=5,
    )
    lines = result.stdout.strip().splitlines()
    if len(lines) != 2:
        return os.path.basename(cwd), None
    common_dir, toplevel = lines
    main_root = os.path.dirname(common_dir)
    worktree = None if toplevel == main_root else os.path.basename(toplevel)
    return os.path.basename(main_root), worktree


def build_title(cwd, transcript_path):
    """"<chat name> / <worktree> / <repo>" — chat name only when set via
    /rename, worktree only when not the main checkout."""
    repo, worktree = worktree_parts(cwd)
    parts = [chat_title(transcript_path), worktree, repo or "Claude"]
    return " / ".join(p for p in parts if p)


def prompt_path(session_id):
    safe = re.sub(r"[^a-zA-Z0-9-]", "", session_id or "unknown")[:64]
    return os.path.join(PROMPTS_DIR, safe)


def save_prompt(session_id, prompt):
    # 0700/0600: prompts are the user's own words — keep them out of reach of
    # other local accounts on shared machines
    os.makedirs(PROMPTS_DIR, mode=0o700, exist_ok=True)
    os.chmod(PROMPTS_DIR, 0o700)
    fd = os.open(prompt_path(session_id), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(prompt or "")
    # opportunistic pruning of long-dead sessions' files
    cutoff = time.time() - 7 * 86400
    for name in os.listdir(PROMPTS_DIR):
        p = os.path.join(PROMPTS_DIR, name)
        try:
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
        except OSError:
            pass


def read_prompt(session_id):
    try:
        with open(prompt_path(session_id)) as f:
            return f.read()
    except OSError:
        return ""


def on_user_prompt_submit(data):
    save_prompt(data.get("session_id"), data.get("prompt", ""))
    group = chat_group(data.get("transcript_path"), data.get("session_id"))
    notifyd({"cmd": "remove", "group": group})


def on_stop(data):
    body = excerpt(read_prompt(data.get("session_id"))) or "done"
    notifyd({
        "cmd": "post",
        "group": chat_group(data.get("transcript_path"), data.get("session_id")),
        "title": build_title(data.get("cwd"), data.get("transcript_path")),
        "message": body,
    })


def on_notification(data):
    message = data.get("message", "")
    if "waiting for" in message.lower() and "input" in message.lower():
        return  # idle reminder, not actionable
    notifyd({
        "cmd": "post",
        "group": chat_group(data.get("transcript_path"), data.get("session_id")),
        "title": build_title(data.get("cwd"), data.get("transcript_path")),
        "message": excerpt(message) or "Notification",
    })


HANDLERS = {
    "UserPromptSubmit": on_user_prompt_submit,
    "Stop": on_stop,
    "Notification": on_notification,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in HANDLERS:
        return
    try:
        data = json.loads(sys.stdin.read() or "{}")
        HANDLERS[sys.argv[1]](data)
    except Exception:
        pass  # a notification hook must never break the agent session


if __name__ == "__main__":
    main()
