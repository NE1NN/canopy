#!/usr/bin/env python3
"""A stand-in for the Canopy iPhone app, for e2e tests: newline-delimited JSON over TCP to the phone listener.

  phone-client.py pair <link> <name> <token-file>       trade the link's code for a token, saved to the file
  phone-client.py call <link> <token-file> <method> [params-json]
                                                        say hello, call one method, print its result as JSON
  phone-client.py hello <link> <token-file>             say hello, print the error code or "ok"
  phone-client.py wait-inbox <link> <token-file> <python-expression> [timeout]
                                                        subscribe, and print the first inbox for which the expression,
                                                        with the inbox as `inbox`, is true
  phone-client.py hold <link> <token-file> <ready-file> say hello, subscribe, touch the ready file, and exit 0 once
                                                        the Mac closes the connection

The link is the canopy-phone://pair URL `canopy phone pair --json` prints; only its host and port are used after pairing.
"""
import json
import os
import socket
import sys
import time
import urllib.parse
import uuid


class Phone:
    def __init__(self, link, timeout=20):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)
        self.code = query["code"][0]
        self.sock = socket.create_connection((query["host"][0], int(query["port"][0])), timeout=timeout)
        self.buffer = b""

    def send(self, method, params=None):
        request_id = str(uuid.uuid4())
        message = {"v": 1, "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.sock.sendall(json.dumps(message).encode() + b"\n")
        return request_id

    def next(self):
        """The next message, or None once the Mac closes the connection."""
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def call(self, method, params=None, on_event=None):
        """Answers to other requests and events that arrive first go to `on_event`."""
        request_id = self.send(method, params)
        while True:
            message = self.next()
            if message is None:
                raise SystemExit(f"the Mac closed the connection before answering {method}")
            if "event" not in message and message.get("id") == request_id:
                return message
            if on_event:
                on_event(message)

    def hello(self, token_file):
        token = open(token_file).read().strip()
        return self.call("phone.hello", {"token": token})


def result_or_exit(response):
    if response.get("error"):
        print(json.dumps(response["error"]))
        sys.exit(1)
    return response.get("result")


def main(args):
    command = args[0]
    if command == "pair":
        link, name, token_file = args[1:4]
        phone = Phone(link)
        result = result_or_exit(phone.call("phone.pair", {"code": phone.code, "name": name}))
        descriptor = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as file:
            file.write(result["token"])
        print(json.dumps({"phone": result["phone"], "mac": result["mac"], "kind": result.get("kind")}))
    elif command == "call":
        link, token_file, method = args[1:4]
        params = json.loads(args[4]) if len(args) > 4 else None
        phone = Phone(link)
        result_or_exit(phone.hello(token_file))
        print(json.dumps(result_or_exit(phone.call(method, params)), sort_keys=True))
    elif command == "hello":
        link, token_file = args[1:3]
        response = Phone(link).hello(token_file)
        print(response["error"]["code"] if response.get("error") else "ok")
    elif command == "hello-json":
        link, token_file = args[1:3]
        print(json.dumps(result_or_exit(Phone(link).hello(token_file)), sort_keys=True))
    elif command == "wait-inbox":
        link, token_file, expression = args[1:4]
        deadline = time.monotonic() + (float(args[4]) if len(args) > 4 else 30)
        phone = Phone(link)
        result_or_exit(phone.hello(token_file))
        inbox = result_or_exit(phone.call("phone.subscribe"))
        while not eval(expression, {}, {"inbox": inbox}):
            phone.sock.settimeout(max(0.1, deadline - time.monotonic()))
            message = phone.next()
            if message is None or time.monotonic() > deadline:
                print(json.dumps(inbox, sort_keys=True), file=sys.stderr)
                raise SystemExit("the inbox never matched " + expression)
            if message.get("event") == "phone.inbox":
                inbox = message["data"]
        print(json.dumps(inbox, sort_keys=True))
    elif command == "hold":
        link, token_file, ready_file = args[1:4]
        phone = Phone(link, timeout=None)
        result_or_exit(phone.hello(token_file))
        result_or_exit(phone.call("phone.subscribe"))
        open(ready_file, "w").close()
        while phone.next() is not None:
            pass
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
