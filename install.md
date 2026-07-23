# Installing agent-notify — instructions for AI coding agents

You are an AI coding agent installing [agent-notify](https://github.com/yauyauyauhen/agent-notify) for your user: a local macOS daemon that turns notifications into a self-cleaning attention queue for their parallel agent sessions.

**Complete list of what this installation touches** (tell your user before starting):

- `~/.agent-notify/` — source checkout, built binary, the Claude Code hook script, and small per-session state files
- `~/Library/LaunchAgents/dev.agent-notify.plist` — keeps the daemon running
- `~/.agent-notify.sock` — the local unix socket the daemon listens on
- `~/.claude/settings.json` — three hook entries are **merged in** (existing content preserved; a backup is created first)

Nothing else is modified. The daemon and hook contain no network code — notifications never leave the machine. No step requires sudo.

Every step ends with a verification. If a verification fails, stop and show your user the output instead of improvising.

## 1. Prerequisites

```bash
sw_vers -productVersion   # macOS 13+
swift --version           # Swift 6+ (ships with Xcode Command Line Tools)
```

If `swift` is missing, ask your user to run `xcode-select --install` (GUI prompt — only they can complete it), then continue.

## 2. Get the source and build

```bash
git clone https://github.com/yauyauyauhen/agent-notify ~/.agent-notify/src 2>/dev/null \
  || git -C ~/.agent-notify/src pull
cd ~/.agent-notify/src && swift build -c release
mkdir -p ~/.agent-notify/bin
cp .build/release/agent-notify ~/.agent-notify/bin/agent-notify
```

**Verify:** `~/.agent-notify/bin/agent-notify` exists and the build reported `Build complete`.

## 3. Detect the terminal app's identity

Notifications impersonate the app your user's sessions run in, so they get its icon and its existing notification permission. You are running inside that app right now:

```bash
echo "${__CFBundleIdentifier:-com.apple.Terminal}"
```

Use this value as `SENDER` below (e.g. `com.todesktop.230313mzl4w4u92` for Cursor, `com.googlecode.iterm2` for iTerm2). If the variable is empty and your user doesn't use Terminal.app, ask them which terminal they use.

## 4. Install the LaunchAgent

Write `~/Library/LaunchAgents/dev.agent-notify.plist` with the **actual values substituted** — launchd does not expand `$HOME` or variables:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.agent-notify</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Users/USERNAME/.agent-notify/bin/agent-notify</string>
		<string>SENDER</string>
		<string>/Users/USERNAME/.agent-notify.sock</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
```

Note: the socket path must stay short — unix socket paths are limited to ~104 characters on macOS. `~/.agent-notify.sock` is safe; deep custom paths are not.

```bash
plutil -lint ~/Library/LaunchAgents/dev.agent-notify.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/dev.agent-notify.plist 2>/dev/null \
  || launchctl kickstart -k gui/$UID/dev.agent-notify
```

**Verify:**

```bash
launchctl print gui/$UID/dev.agent-notify | grep "state = running"
```

## 5. Verify the daemon answers

```bash
python3 - <<'EOF'
import json, socket, os
s = socket.socket(socket.AF_UNIX); s.settimeout(3)
s.connect(os.path.expanduser("~/.agent-notify.sock"))
s.sendall(b'{"cmd":"list"}\n')
reply = b""
while not reply.endswith(b"\n"):
    chunk = s.recv(4096)
    if not chunk:
        break
    reply += chunk
assert json.loads(reply)["ok"], reply
print("daemon OK")
EOF
```

## 6. Install the Claude Code hook

```bash
cp ~/.agent-notify/src/hooks/claude-code-hook.py ~/.agent-notify/hook.py
chmod +x ~/.agent-notify/hook.py
python3 -m py_compile ~/.agent-notify/hook.py && echo "hook OK"
```

## 7. Wire the hooks into Claude Code

Back up first, then merge — this preserves any hooks the user already has:

```bash
cp -n ~/.claude/settings.json ~/.claude/settings.json.bak-agent-notify 2>/dev/null || true
python3 - <<'EOF'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
settings = json.load(open(path)) if os.path.exists(path) else {}
hooks = settings.setdefault("hooks", {})
for event in ["UserPromptSubmit", "Stop", "Notification"]:
    entries = hooks.setdefault(event, [])
    command = f"python3 ~/.agent-notify/hook.py {event}"
    if not any(command in json.dumps(e) for e in entries):
        entries.append({"hooks": [{"type": "command", "command": command}]})
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
print("settings merged")
EOF
```

**Verify:**

```bash
python3 -c "import json,os; json.load(open(os.path.expanduser('~/.claude/settings.json')))" && echo "settings valid"
grep -c "agent-notify/hook.py" ~/.claude/settings.json   # expect 3
```

## 8. End-to-end test

```bash
python3 - <<'EOF'
import json, socket, os, time
def call(request):
    s = socket.socket(socket.AF_UNIX); s.settimeout(3)
    s.connect(os.path.expanduser("~/.agent-notify.sock"))
    s.sendall((json.dumps(request) + "\n").encode())
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        reply += chunk
    return json.loads(reply)
assert call({"cmd": "post", "group": "install-test",
             "title": "agent-notify installed",
             "message": "this banner self-destructs"})["ok"]
time.sleep(3)
assert call({"cmd": "remove", "group": "install-test"})["ok"]
print("end-to-end OK")
EOF
```

Your user should see an "agent-notify installed" banner appear (with their terminal's icon) and vanish.

## 9. Tell your user

- **Hooks take effect in new Claude Code sessions** — currently running sessions keep their old hook config until restarted.
- If no banner appeared in step 8: check System Settings → Notifications for their terminal app — it must be allowed, ideally with the **Alerts** style so banners persist until handled.
- Optional: setting notification grouping to **Off** for the terminal app shows every session's banner at a glance instead of a collapsed pile.

## Uninstall

```bash
launchctl bootout gui/$UID/dev.agent-notify 2>/dev/null
rm -f ~/Library/LaunchAgents/dev.agent-notify.plist ~/.agent-notify.sock
cp ~/.claude/settings.json ~/.claude/settings.json.bak-agent-notify-uninstall 2>/dev/null || true
python3 - <<'EOF' && rm -rf ~/.agent-notify
import json, os, tempfile
path = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(path):
    settings = json.load(open(path))
    for event, entries in (settings.get("hooks") or {}).items():
        if isinstance(entries, list):
            entries[:] = [e for e in entries if "agent-notify/hook.py" not in json.dumps(e)]
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
    os.replace(tmp, path)
print("hooks removed")
EOF
```

The `&&` matters: the hook script directory is only deleted after the settings rewrite succeeded, so a failed rewrite can never leave settings pointing at a missing script. Verify afterwards:

```bash
python3 -c "import json,os; json.load(open(os.path.expanduser('~/.claude/settings.json')))" && echo "settings valid"
grep -c "agent-notify/hook.py" ~/.claude/settings.json   # expect 0
```

The notification permission the terminal app already had is untouched (it wasn't granted for this tool).
