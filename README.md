# agent-notify

**One daemon to own all your CLI notifications on macOS — because one process per banner is a race condition.**

If you run multiple parallel AI coding sessions (Claude Code, Codex, Cursor agents) with completion notifications — for example via [CCNotify](https://github.com/dazuiba/CCNotify) — you may have seen notifications misbehave in ways that look haunted:

- you click **one** notification and **several** disappear;
- a new notification from one session silently kills another session's banner;
- a notification is "sent" but never appears;
- the same setup works fine for days, then wipes your whole stack twice in an hour.

None of that is random. This repo contains the diagnosis and the fix.

## The bug

CLI notifiers like [alerter](https://github.com/vjeantet/alerter) and [terminal-notifier](https://github.com/julienXX/terminal-notifier) impersonate a real app's bundle identifier (your terminal's, usually) so their notifications get that app's icon and notification permission. `alerter` additionally keeps **one process alive per banner** so it can report clicks.

Run several of those at once and every process claims the *same* app identity. Inside macOS's notification daemon (`usernoted`) they now share everything that is keyed by app:

- **one delivered-notifications list** — every process sees (and can remove from) the shared list;
- **one delegate slot** for click callbacks — each new process steals it, so click events are routed to whichever process registered last, not necessarily the one that posted the clicked banner;
- **per-connection bookkeeping** — when a process exits *while its banner is still registered*, `usernoted`'s connection cleanup sometimes sweeps **sibling banners of the same identity** along with it.

That last one is the killer, and it's a race — which is why it strikes "often" rather than "always", and why every flag-level fix (timeouts, groups, different removal calls) appears to work until it doesn't. Killing a notification process while its banner is up is the most reliable trigger; a user *clicking* a banner sits in the same window, because macOS removes the banner and the process exits within the same instant.

We reproduced all of this live: single-pid `kill` of one alerter took down a sibling's banner posted by a *different* process, with the kill pattern provably matching only one of them. The alerter source is innocent — its removal paths are all correctly scoped. The sharing itself is the bug, and no flag can fix an architecture.

## The fix

Stop sharing. **agent-notify** is a single long-lived daemon that owns *all* banners through *one* notification-center connection:

- it never exits per-notification, so the connection-cleanup race cannot occur — not "is unlikely to", *cannot, by construction*;
- clicks route to the one process that owns everything, which dismisses exactly the clicked banner (matched by identifier) and focuses the impersonated app;
- replacement and removal are plain list operations on the owner's connection;
- and as the owner, it can **truthfully enumerate what's on screen** — something no outside process can do for an impersonated identity (`--list` in the CLI tools is blind for spoofed senders; with a supervisor you finally get ground truth).

The delivery internals (bundle-identifier hook, alert-style plumbing) are adapted from [alerter](https://github.com/vjeantet/alerter) (MIT) — credit where due; the supervisor architecture and the protocol are new.

## Install

Requires Xcode (or Command Line Tools with Swift 6+).

```bash
git clone https://github.com/YOU/agent-notify && cd agent-notify
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

The impersonated app must already have notification permission (style "Alerts" if you want banners to persist).

## Protocol

Newline-delimited JSON over the unix socket. One request, one reply, per connection.

```jsonc
{"cmd":"post","group":"my-session","title":"build done","message":"47 tests passed"}
// -> {"ok":true}    (a new post replaces any previous banner with the same group)

{"cmd":"remove","group":"my-session"}
// -> {"ok":true,"removed":1}

{"cmd":"list"}
// -> {"ok":true,"notifications":[{"group":"...","title":"...","message":"...","deliveredAt":"..."}]}
```

A minimal Python client ships in [`client/agent-notify-client.py`](client/agent-notify-client.py):

```bash
./client/agent-notify-client.py post my-session "build done" "47 tests passed"
./client/agent-notify-client.py list
./client/agent-notify-client.py remove my-session
```

### Claude Code integration

Use the session ID as the group and you get per-chat semantics for free: each chat's new notification replaces its previous one, chats never touch each other, and a `remove` on `UserPromptSubmit` gives you "typing in a chat dismisses that chat's notification":

```python
# inside your Stop hook
call({"cmd": "post", "group": session_id, "title": chat_title, "message": prompt_excerpt})

# inside your UserPromptSubmit hook
call({"cmd": "remove", "group": session_id})
```

## Caveats, honestly

- Built on `NSUserNotification`, which Apple deprecated years ago and keeps shipping anyway (every CLI notifier relies on it — the modern `UserNotifications` framework requires a signed app bundle). A future macOS may break this entire tool category at once.
- Bundle-identifier impersonation is a runtime swizzle of `NSBundle` — a well-worn community trick, not API.
- One daemon serves one impersonated identity. Run a second instance (different socket) for a second identity.

## Credits

- [alerter](https://github.com/vjeantet/alerter) by Valère Jeantet and contributors — delivery internals, MIT.
- [CCNotify](https://github.com/dazuiba/CCNotify) by dazuiba — the Claude Code notification hook this was born debugging.

MIT © Eugene Klishevich
