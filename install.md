# Installing agent-notify — instructions for AI coding agents

You are an AI coding agent installing [agent-notify](https://github.com/yauyauyauhen/agent-notify) for your user: a local macOS daemon that turns notifications into a self-cleaning attention queue for their parallel agent sessions.

**Complete list of what this installation touches** (tell your user before starting):

- `~/.agent-notify/` — source checkout, the assembled `AgentNotify.app` bundle, the Claude Code hook script, a daemon log, and small per-session state files
- `~/Library/LaunchAgents/dev.agent-notify.plist` — keeps the daemon running
- `~/.agent-notify.sock` — the local unix socket the daemon listens on
- `~/.claude/settings.json` — five hook entries are **merged in** (existing content preserved; a backup is created first)
- One macOS notification-permission grant for **AgentNotify** (the user clicks Allow, once)

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
```

**Verify:** the build reported `Build complete`.

## 3. Assemble the app bundle

The daemon must live inside a real `.app` bundle — the bundle is its notification identity: macOS grants notification permission per bundle id, and the modern UserNotifications API only serves bundled apps.

```bash
mkdir -p ~/.agent-notify/AgentNotify.app/Contents/MacOS \
         ~/.agent-notify/AgentNotify.app/Contents/Resources
cp ~/.agent-notify/src/.build/release/agent-notify \
   ~/.agent-notify/AgentNotify.app/Contents/MacOS/agent-notify
cp ~/.agent-notify/src/examples/AgentNotify-Info.plist \
   ~/.agent-notify/AgentNotify.app/Contents/Info.plist
codesign --force --sign - ~/.agent-notify/AgentNotify.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f ~/.agent-notify/AgentNotify.app
```

Optional — give banners your terminal's icon (they use the generic app icon otherwise). Example for Ghostty; any `.icns` works:

```bash
cp /Applications/Ghostty.app/Contents/Resources/Ghostty.icns \
   ~/.agent-notify/AgentNotify.app/Contents/Resources/AppIcon.icns
codesign --force --sign - ~/.agent-notify/AgentNotify.app
```

**Verify:**

```bash
plutil -lint ~/.agent-notify/AgentNotify.app/Contents/Info.plist
codesign --verify ~/.agent-notify/AgentNotify.app && echo "bundle OK"
```

## 4. Detect the terminal to focus on click

Clicking a banner brings the user's terminal forward. You are running inside that terminal right now:

```bash
echo "${__CFBundleIdentifier:-com.apple.Terminal}"
```

Use this value as `FOCUS_BUNDLE_ID` below (e.g. `com.mitchellh.ghostty` for Ghostty, `com.googlecode.iterm2` for iTerm2, `com.todesktop.230313mzl4w4u92` for Cursor). If the variable is empty and your user doesn't use Terminal.app, ask them which terminal they use.

## 5. Install the LaunchAgent

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
		<string>/Users/USERNAME/.agent-notify/AgentNotify.app/Contents/MacOS/agent-notify</string>
		<string>FOCUS_BUNDLE_ID</string>
		<string>/Users/USERNAME/.agent-notify.sock</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardErrorPath</key>
	<string>/Users/USERNAME/.agent-notify/daemon.log</string>
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

## 6. Notification permission — needs the user

First launch makes macOS ask for notification permission for **AgentNotify**. On current macOS the request itself arrives **as a notification** ("AgentNotify" Notifications / Notifications may include alerts, sounds, and icon badges). Tell your user to:

1. Click that notification and choose **Allow**.
2. In System Settings → Notifications → **AgentNotify**: set the style to **Alerts** (banners persist until handled — the attention-queue behavior depends on this) and set **grouping to Off** (every session's banner visible at a glance instead of a collapsed pile).

**Verify** (only true after the user clicks Allow):

```bash
grep "authorization granted=true" ~/.agent-notify/daemon.log
```

## 7. Verify the daemon answers

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

## 8. Install the Claude Code hook

```bash
cp ~/.agent-notify/src/hooks/claude-code-hook.py ~/.agent-notify/hook.py
chmod +x ~/.agent-notify/hook.py
python3 -m py_compile ~/.agent-notify/hook.py && echo "hook OK"
```

## 9. Wire the hooks into Claude Code

Back up first, then merge — this preserves any hooks the user already has:

```bash
cp -n ~/.claude/settings.json ~/.claude/settings.json.bak-agent-notify 2>/dev/null || true
python3 - <<'EOF'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
settings = json.load(open(path)) if os.path.exists(path) else {}
hooks = settings.setdefault("hooks", {})
for event in ["UserPromptSubmit", "Stop", "Notification", "SessionStart", "SessionEnd"]:
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
grep -c "agent-notify/hook.py" ~/.claude/settings.json   # expect 5
```

## 10. End-to-end test

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

Your user should see an "agent-notify installed" banner appear and vanish.

## 11. Tell your user

- **Hooks take effect in new Claude Code sessions** — currently running sessions keep their old hook config until restarted.
- If no banner appeared in step 10: the permission from step 6 was probably not granted — check System Settings → Notifications → AgentNotify.
- If Claude Code also posts its own native notifications in this terminal (Ghostty, Kitty and iTerm2 do this: "Claude Code — Claude is waiting for your input"), those are a separate, unmanaged path that duplicates agent-notify. Turning notifications **off for the terminal app** in System Settings silences the duplicates without touching agent-notify — it uses its own permission, not the terminal's.

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

The AgentNotify entry in System Settings → Notifications disappears on its own once macOS notices the app is gone; it holds no data either way.
