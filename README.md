# agent-notify

**Turn macOS notifications into a self-cleaning attention queue for the AI-agent sessions in your terminal.**

## The problem it solves

You run several Claude Code (or Codex, or Cursor-agent) sessions side by side, and each takes a while to finish. A ding tells you *something* replied — but not *which session*. The banners themselves pile up, go stale, or vanish when they shouldn't, and figuring out which agent actually needs you becomes its own job.

## The solution

agent-notify makes the notification stack itself the answer — a live list of exactly the sessions awaiting you:

- **One notification banner on screen per agent session** — each finished (or input-waiting) session holds exactly one banner. The stack *is* your "sessions awaiting me" list.
- **Self-cleaning** — a session's next notification replaces its previous one in place, and the moment you follow up in a chat, its banner disappears on its own. No duplicates, no stale pile: what's on screen is only what still needs you.
- **Easy to scan** — banners are titled `chat name / worktree / repo`, with the worktree shown only when it isn't the main checkout. Name your chats (`/rename` in Claude Code) and the stack reads like a status board.
- **Click to jump and dismiss** — clicking a banner dismisses exactly that one and focuses your terminal; every other agent's notification stays put until you click it or follow up with that agent.
- **Reliable by architecture** — existing CLI notifiers (alerter, terminal-notifier) spawn one process per banner, and those processes randomly wipe each other's notifications when several run at once (see [the bug](#the-bug-this-fixes) below). agent-notify is a single daemon that owns every banner through one connection, so that entire failure class can't happen.

Notifications appear under your terminal app's identity (its icon, its permission) — Cursor, iTerm2, Terminal, whatever you use.

**Tip:** to see every session's banner at a glance instead of a collapsed pile, set notification grouping to **Off** for your terminal app in macOS notification settings.

## Install

**Fastest — let your agent do it.** Paste this into Claude Code:

> Install agent-notify by following https://github.com/yauyauyauhen/agent-notify/blob/main/install.md

Your agent builds the daemon, detects your terminal app, sets up the LaunchAgent, and wires the ready-made Claude Code hook — [install.md](install.md) tells it exactly what to touch, how to verify every step, and how to uninstall. Out of the box this covers Claude Code; any other agent runner works via the three-command [protocol](#protocol).

**Manual** — requires the Command Line Tools (Swift 6+ ships with them):

```bash
git clone https://github.com/yauyauyauhen/agent-notify && cd agent-notify
swift build -c release
cp .build/release/agent-notify /usr/local/bin/
```

Run it with the bundle ID you want notifications attributed to, and a socket path:

```bash
agent-notify com.todesktop.230313mzl4w4u92 ~/.agent-notify.sock   # Cursor
# or com.googlecode.iterm2, com.apple.Terminal, ...
```

For always-on use, install the LaunchAgent from [`examples/dev.agent-notify.plist`](examples/dev.agent-notify.plist) (edit the paths and bundle ID):

```bash
cp examples/dev.agent-notify.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/dev.agent-notify.plist
```

The impersonated app must already have notification permission, with style "Alerts" so banners persist until handled.

## Claude Code integration

The ready-made hook ships in [`hooks/claude-code-hook.py`](hooks/claude-code-hook.py) — the agent install wires it up for you. It implements everything the attention-queue behavior needs:

- posts on `Stop` — title `chat name / worktree / repo`, body = your prompt, flattened and truncated to read as ~2 banner lines;
- dismisses that chat's banner on `UserPromptSubmit`; shows `Notification` events' real text and suppresses idle "waiting for input" reminders;
- keys banners by a **stable chat identity** (the uuid of the transcript's first user record), not the raw `session_id` — resuming a chat (`--resume`) mints a new session ID, and session-keyed banners would orphan on every resume. It also ignores a `/rename` title inherited through `/clear`.

Integrating a different agent runner? The hook is ~150 lines of dependency-free Python over the three-command protocol below — adapt away.

`call()` is a ~10-line unix-socket helper; a ready-made client ships in [`client/agent-notify-client.py`](client/agent-notify-client.py):

```bash
./client/agent-notify-client.py post my-session "build done" "47 tests passed"
./client/agent-notify-client.py list
./client/agent-notify-client.py remove my-session
```

This pairs naturally with [CCNotify](https://github.com/dazuiba/CCNotify), the Claude Code notification hook this project was born debugging.

## Protocol

Newline-delimited JSON over the unix socket. One request, one reply, per connection.

```jsonc
{"cmd":"post","group":"my-session","title":"build done","message":"47 tests passed"}
// -> {"ok":true}    (replaces any previous banner with the same group)

{"cmd":"remove","group":"my-session"}
// -> {"ok":true,"removed":1}

{"cmd":"list"}
// -> {"ok":true,"notifications":[{"group":"...","title":"...","message":"...","deliveredAt":"..."}]}
```

`list` is ground truth: as the owner of the notification connection, the daemon can truthfully enumerate what's on screen — something no outside process can do for an impersonated identity.

## The bug this fixes

Classic CLI notifiers impersonate your terminal's bundle ID and keep one process alive per banner. Run several in parallel and every process claims the *same* app identity inside macOS's notification daemon — sharing one delivered-notifications list, one delegate slot for click routing, and per-connection bookkeeping. When any process exits while its banner is still registered, the cleanup sometimes sweeps *sibling* banners along with it.

In practice that looks haunted: clicking one notification dismisses several; a new notification from one session silently kills another session's banner; the same setup works for days, then wipes your stack twice in an hour. It's a race, so it strikes "often", not "always" — and no flag can fix it, because the sharing itself is the bug (the notifier tools' own removal code is correctly scoped; we read it). A single supervisor owning all banners through one connection eliminates the race by construction. Full write-up in [vjeantet/alerter#75](https://github.com/vjeantet/alerter/issues/75).

## Caveats

- Built on `NSUserNotification`, which Apple deprecated years ago and keeps shipping anyway (every CLI notifier relies on it — the modern `UserNotifications` framework requires a signed app bundle). A future macOS may break this entire tool category at once.
- Bundle-identifier impersonation is a runtime swizzle of `NSBundle` — a well-worn community trick, not API.
- One daemon serves one impersonated identity. Run a second instance (different socket) for a second identity.

## Credits

- [alerter](https://github.com/vjeantet/alerter) by Valère Jeantet and contributors — delivery internals, MIT.
- [CCNotify](https://github.com/dazuiba/CCNotify) by dazuiba — the Claude Code notification hook this was born debugging.

MIT © Eugene Klishevich
