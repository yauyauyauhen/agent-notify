#!/usr/bin/env python3
"""Minimal client for agent-notify.

Usage:
  agent-notify-client.py post   <group> <title> <message>
  agent-notify-client.py remove <group>
  agent-notify-client.py list

Socket path comes from $AGENT_NOTIFY_SOCKET (default ~/.agent-notify.sock).
"""

import json
import os
import socket
import sys

SOCKET_PATH = os.environ.get(
    "AGENT_NOTIFY_SOCKET", os.path.expanduser("~/.agent-notify.sock")
)


def call(request: dict) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(SOCKET_PATH)
    s.sendall((json.dumps(request) + "\n").encode())
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        reply += chunk
    s.close()
    return json.loads(reply)


def main() -> None:
    args = sys.argv[1:]
    if args[:1] == ["post"] and len(args) == 4:
        request = {"cmd": "post", "group": args[1], "title": args[2], "message": args[3]}
    elif args[:1] == ["remove"] and len(args) == 2:
        request = {"cmd": "remove", "group": args[1]}
    elif args[:1] == ["list"] and len(args) == 1:
        request = {"cmd": "list"}
    else:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    print(json.dumps(call(request), indent=2))


if __name__ == "__main__":
    main()
