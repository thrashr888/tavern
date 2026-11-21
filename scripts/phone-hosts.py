#!/usr/bin/env python3
"""Adds each Pi agent's durable host, by tailnet (MagicDNS) name, to the phone's party.json, so the
iPhone app adds the party itself. Reads `tailscale status --json` on stdin. Each host serves its
agent's port on the tailnet with `tailscale serve --tcp <port> tcp://127.0.0.1:<port>`; an agent
on this Mac (127.0.0.1) gets this Mac's name.
    tailscale status --json | scripts/phone-hosts.py roster.json iOS/Party/party.json"""
import json
import subprocess
import sys

status = json.load(sys.stdin)
suffix = status.get("MagicDNSSuffix", "")
me = status.get("Self", {}).get("DNSName", "").rstrip(".")
rows = subprocess.run([sys.executable, __file__.replace("phone-hosts.py", "phone-agents.py"), sys.argv[1]],
                      capture_output=True, text=True, check=True).stdout
hosts = []
for row in rows.splitlines():
    name, kind, host, port = row.split("\t")
    if host in ("127.0.0.1", "localhost"):
        host = me
    elif suffix and "." not in host:
        host = f"{host}.{suffix}"
    if host:
        hosts.append({"id": name.lower(), "name": name, "host": host, "port": int(port)})
party = json.load(open(sys.argv[2]))
party["hosts"] = hosts
json.dump(party, open(sys.argv[2], "w"))
