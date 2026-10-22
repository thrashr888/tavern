#!/usr/bin/env python3
"""Prints each Pi agent in a Tavern roster.json as name, kind (tcp or ssh), host and port, one
per line, tab-separated, for scripts/phone.sh."""
import json
import re
import sys

for member in json.load(open(sys.argv[1])).get("members", []):
    if member.get("kind") != "pi":
        continue
    endpoint = member.get("piEndpoint") or {}
    if endpoint.get("kind") == "tcp":
        print(f"{member['name']}\ttcp\t{endpoint['host']}\t{endpoint['port']}")
    elif endpoint.get("kind") == "command":
        argv = endpoint.get("argv", [])
        port = next((p for a in argv for p in re.findall(r"TCP:127\.0\.0\.1:(\d+)", a)), None)
        if argv and argv[0].endswith("ssh") and port:
            host = next((a for a in argv[1:] if not a.startswith("-") and "=" not in a and "socat" not in a), None)
            if host:
                print(f"{member['name']}\tssh\t{host}\t{port}")
