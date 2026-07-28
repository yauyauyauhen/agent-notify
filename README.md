# agent-notify

**Turn macOS notifications into a self-cleaning attention queue for the AI-agent sessions in your terminal.**

## The problem it solves

You run several Claude Code (or Codex, or Cursor-agent) sessions side by side, and each takes a while to finish. A ding tells you *something* replied — but not *which session*. The banners themselves pile up, go stale, or vanish when they shouldn't, and figuring out which agent actually needs you becomes its own job.

## The solution

agent-notify makes the notification stack itself the answer: a live list of exactly the sessions awaiting you.

- **One banner per agent session**
  - each finished or input-waiting session holds exactly one banner
  - the stack on your screen *is* your "sessions awaiting me" list
- **Self-cleaning**
  - a session's next notification replaces its previous one in place
  - a banner dismisses itself the moment it stops being relevant: you reply in the chat, `/clear` it, `/exit` the session, or close its terminal window
  - merely clicking into the session's chat never dismisses its banner: only your deliberate reaction does, not a stray click or an accidental read
  - dismiss right from the session chat with **`/ok`**, the shipped slash command that clears the banner without costing an LLM turn
- **Easy to scan**
  - banners are titled `chat name / worktree / repo`, with the worktree shown only when it isn't the main checkout
  - name your chats (`/rename` in Claude Code) and the stack reads like a status board
- **Click to jump and dismiss**
  - clicking a banner dismisses exactly that one and focuses your terminal
  - clicking can raise the specific window the session lives in, including windows on other Spaces: grant the daemon Accessibility (optional, one click); without the grant, you get app-level focus
- **Reliable notification handling**
  - banners never randomly wipe each other, the failure class that haunts classic CLI notifiers
  - it can't happen here by construction: a single daemon owns every banner through one connection to macOS's notification system, using the modern `UserNotifications` API under its own app identity (see [why](#why-not-alerter-or-terminal-notifier) below)

agent-notify runs as its own tiny background app with its own notification permission — it doesn't impersonate or depend on your terminal. Clicking a banner focuses whichever terminal you configure: I run it with **Ghostty**, and it works the same with iTerm2, Cursor, Terminal.app, Kitty, or anything else with a bundle id. Banners can wear your terminal's icon — drop its `.icns` into the app bundle (one optional install step).

**Tip:** to see every session's banner at a glance instead of a collapsed pile, set notification grouping to **Off** for AgentNotify in macOS notification settings — and use the **Alerts** style so banners persist until handled.

## Install

**Fastest — let your agent do it.** Paste this into Claude Code:

> Install agent-notify by following https://github.com/yauyauyauhen/agent-notify/blob/main/install.md

Your agent builds the daemon, assembles the app bundle, detects your terminal, sets up the LaunchAgent, and wires the ready-made Claude Code hook — [install.md](install.md) tells it exactly what to touch, how to verify every step, and how to uninstall. You click **Allow** once when macOS asks for notification permission. Out of the box this covers Claude Code; any other agent runner works via the five-command [protocol](#protocol).

**Manual** — requires the Command Line Tools (Swift 6+ ships with them). Follow the same steps install.md gives an agent: build, assemble `AgentNotify.app` (the bundle is the daemon's notification identity — the [Info.plist template](examples/AgentNotify-Info.plist) ships in `examples/`), install the [LaunchAgent](examples/dev.agent-notify.plist), grant permission, set Alerts style. The short version:

```bash
git clone https://github.com/yauyauyauhen/agent-notify && cd agent-notify
swift build -c release
# then follow install.md §3–6 to assemble the bundle and LaunchAgent
```

## Claude Code integration

The ready-made hook ships in [`hooks/claude-code-hook.py`](hooks/claude-code-hook.py) — the agent install wires it up for you. It implements everything the attention-queue behavior needs:

- posts on `Stop` — title `chat name / worktree / repo`, body = your prompt, flattened and truncated to read as ~2 banner lines;
- dismisses that chat's banner on `UserPromptSubmit`; shows `Notification` events' real text and suppresses idle "waiting for input" reminders;
- keys banners by a **stable chat identity** (the uuid of the transcript's first user record), not the raw `session_id` — resuming a chat (`--resume`) mints a new session ID, and session-keyed banners would orphan on every resume;
- ships a **`/ok` slash command** ([`commands/ok.md`](commands/ok.md)): typing it in a chat dismisses that chat's banner with **zero LLM cost** — the hook intercepts and blocks the prompt before it reaches the model, so it never enters context and the conversation is untouched;
- handles `/clear` correctly: the chat keeps its `/rename` name but gets a new identity, so for named chats the newer banner replaces the same-titled older one, and the session lifecycle events (`SessionStart`/`SessionEnd`) dismiss banners a session leaves behind.

Integrating a different agent runner? The hook is ~300 lines of dependency-free Python over the five-command protocol below — adapt away.

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
// -> {"ok":true}    (replaces any previous banner with the same group, in place)
// optional: "replace_same_title":true also replaces same-titled banners from
// other groups — for sessions that keep their name but change identity

{"cmd":"remove","group":"my-session"}
// -> {"ok":true,"removed":1}

{"cmd":"remove-title","title":"build done"}
// -> {"ok":true,"removed":1}

{"cmd":"list"}
// -> {"ok":true,"notifications":[{"group":"...","title":"...","message":"...","deliveredAt":"..."}]}

{"cmd":"windows"}
// -> {"ok":true,"windows":["travel-planner","blog"]}   (diagnostic: the focus
//    target's window titles as Accessibility sees them, current Space only)
```

`list` is ground truth: the daemon owns every banner it posted, so what it enumerates is what's on screen.

## Why not alerter or terminal-notifier?

The classic CLI notifiers impersonate your terminal's bundle ID over the deprecated `NSUserNotification` API and keep one process alive per banner. Building an attention queue on top of them fails in two ways — both discovered the hard way while building this tool:

**The race.** Run several notifier processes in parallel and every one claims the *same* app identity inside macOS's notification daemon — sharing one delivered-notifications list, one delegate slot for click routing, and per-connection bookkeeping. When any process exits while its banner is still registered, the cleanup sometimes sweeps *sibling* banners along with it. In practice that looks haunted: clicking one notification dismisses several; a new notification from one session silently kills another session's banner; the same setup works for days, then wipes your stack twice in an hour. No flag can fix it, because the sharing itself is the bug. Full write-up in [vjeantet/alerter#75](https://github.com/vjeantet/alerter/issues/75).

**The wall.** Impersonation only ever worked for app identities that never touch the notification system themselves. The moment your terminal is a *real* notification client — Ghostty, for instance, registers with the modern `UserNotifications` API — macOS hard-rejects every legacy connection claiming its identity: `Legacy client connecting to modern client. You can't mix modern clients with legacy clients`, straight from `usernoted`. Deliveries are silently denied with no error surfaced to the caller. The trick isn't just racy; for modern terminals it's impossible.

agent-notify is built where those problems can't exist: one long-lived daemon, its own app identity, the modern API — first-class in-place replacement, reliable removal and enumeration, proper click routing. (Historical footnote: v1 of this project fixed the race while still impersonating; the wall is what killed impersonation for good.)

## Caveats

- macOS notification permission is granted per app, by a human: after install, one **Allow** click, plus setting the style to **Alerts** in System Settings (the default Banners style auto-hides after a few seconds, which defeats an attention queue).
- Window targeting matches on window *titles* (a window shows its focused pane's title), so it's exact for one-window-per-project layouts and degrades gracefully to app focus otherwise. Pane-level jumping has no public interface in any terminal we know of.
- The app bundle is ad-hoc signed at install time — fine for a LaunchAgent on your own machine. One consequence: macOS ties Accessibility grants to the code signature, so after **updating** the daemon you may need to re-grant (toggle off/on, or `tccutil reset Accessibility dev.agent-notify.app` and re-approve). Signing with a stable local certificate identity makes grants survive updates; distribution through Gatekeeper would need a real one.
- A force-killed terminal fires no hooks, so its last banner stays until clicked. Physics.

## Credits

- [alerter](https://github.com/vjeantet/alerter) by Valère Jeantet and contributors — v1 was built on its delivery internals, and its multi-process race is the bug that started this project. MIT.
- [CCNotify](https://github.com/dazuiba/CCNotify) by dazuiba — the Claude Code notification hook this was born debugging.

MIT © Eugene Klishevich
