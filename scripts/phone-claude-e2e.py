#!/usr/bin/env python3
"""Drives a real Claude Code in a dev build's pane the way the iPhone app will, through the phone listener.

  phone-claude-e2e.py <pairing link> <token file> <pane> <work folder>

Checks, against Claude Code with Haiku:
  - the folder trust dialog answered with phone.keys
  - a long multi-line reply lands whole in the transcript
  - an AskUserQuestion answered from the phone
  - a Bash permission prompt allowed, and another denied
  - Delivered after each reply
Prints each step, and exits 1 on the first failure.
"""
import importlib.util
import json
import os
import sys
import time

spec = importlib.util.spec_from_file_location("phone_client", os.path.join(os.path.dirname(__file__), "phone-client.py"))
phone_client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phone_client)

link, token_file, pane, folder = sys.argv[1:5]


def step(text):
    print(f"\n--> {text}", flush=True)


def fail(text):
    print(f"FAIL: {text}", file=sys.stderr, flush=True)
    sys.exit(1)


class Session:
    """One phone connection with the inbox subscribed, keeping every event it sees."""

    def __init__(self):
        self.phone = phone_client.Phone(link, timeout=5)
        self.phone.sock.settimeout(None)
        if (error := self.phone.hello(token_file).get("error")):
            fail(f"hello: {error}")
        self.inbox = {"rows": []}
        self.delivered = set()
        self.transcript = {}
        self.inbox = self.call("phone.subscribe")
        self.delivered = set()
        self.transcript = {}

    def call(self, method, params=None):
        self.phone.sock.settimeout(60)
        response = self.phone.call(method, params, on_event=self.take)
        if response.get("error"):
            raise RuntimeError(f"{method}: {response['error']}")
        return response.get("result")

    def pump(self, seconds):
        """Reads events for up to `seconds`."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.phone.sock.settimeout(max(0.05, deadline - time.monotonic()))
            try:
                message = self.phone.next()
            except TimeoutError:
                return
            except OSError:
                return
            if message is None:
                fail("the Mac closed the connection")
            self.take(message)

    def take(self, message):
        event = message.get("event")
        if event == "phone.inbox":
            self.inbox = message["data"]
        elif event == "phone.delivered":
            self.delivered.add(message["data"]["reply"])
        elif event == "phone.transcript":
            for entry in message["data"]["entries"]:
                self.transcript[entry["id"]] = entry

    def agent(self):
        for row in self.inbox["rows"]:
            for agent in row["agents"]:
                if agent["pane"] == pane:
                    return agent
        return None

    def wait(self, what, check, seconds=180):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            result = check()
            if result:
                return result
            self.pump(0.5)
        agent = self.agent()
        fail(f"timed out waiting for {what}; agent: {json.dumps(agent)}")

    def screen(self):
        return "\n".join(self.call("phone.screen", {"pane": pane})["lines"])

    def entries(self):
        return list(self.transcript.values())


session = Session()

step("Claude Code starts, and its folder trust dialog is answered with phone.keys")
screen = session.wait("Claude Code to start", lambda: (s := session.screen()) and ("trust" in s or "❯" in s) and s, 90)
if "Yes, I trust this folder" in screen:
    session.call("phone.keys", {"pane": pane, "text": "\x1b[B"})
    time.sleep(0.5)
    session.call("phone.keys", {"pane": pane, "text": "\r"})
session.wait("the prompt", lambda: "Yes, I trust this folder" not in session.screen() and "❯" in session.screen(), 60)
time.sleep(2)

step("a long multi-line reply lands whole")
lines = [f"Line {n:02d}: the quick brown fox jumps over the lazy dog, again and again." for n in range(1, 41)]
long_reply = "Here are 40 numbered lines. Reply with only the number of the last line, and use no tools.\n" + "\n".join(lines)
reply = session.call("phone.reply", {"pane": pane, "text": long_reply})["reply"]
session.wait("the reply to be delivered", lambda: reply in session.delivered, 60)
session.wait("the agent to finish", lambda: (a := session.agent()) and a["state"] == "done", 120)
page = session.call("phone.transcript", {"pane": pane, "limit": 20, "follow": True})
prompts = [e for e in page["entries"] if e["kind"] == "prompt"]
if not prompts or prompts[-1]["text"] != long_reply:
    fail(f"the transcript's prompt is not the whole reply: {json.dumps(prompts[-1:])[:400]}")
answers = [e for e in page["entries"] if e["kind"] == "text"]
print(f"   prompt arrived whole ({len(long_reply)} characters); Claude answered {answers[-1]['text']!r}" if answers else "   no answer text")
session.transcript = {e["id"]: e for e in page["entries"]}

step("an AskUserQuestion is answered from the phone")
reply = session.call(
    "phone.reply",
    {"pane": pane, "text": "Use the AskUserQuestion tool to ask me whether to name a new file c.txt or d.txt, with exactly those two options. Do not create it."},
)["reply"]
agent = session.wait("the question", lambda: (a := session.agent()) and a.get("prompt", {}) and a["prompt"]["kind"] == "question" and a)
print(f"   inbox: {agent['lastLine']}")
labels = [o["label"] for o in agent["prompt"]["questions"][0]["options"]]
choice = labels.index("d.txt") if "d.txt" in labels else 1
session.call("phone.answer", {"pane": pane, "prompt": agent["prompt"]["id"], "answer": {"options": [[choice]]}})
session.wait("the answer in the transcript", lambda: any(e["kind"] == "question" and e.get("answer") == labels[choice] for e in session.entries()))
session.wait("the agent to finish", lambda: (a := session.agent()) and a["state"] in ("done", "waiting") and not a.get("prompt"))
if reply not in session.delivered:
    fail("the question's reply was never delivered")

def answer_question(text, pick):
    """Asks for a picker, answers it with `pick(questions)`, and returns the answer the transcript shows."""
    session.call("phone.reply", {"pane": pane, "text": text})
    agent = session.wait("the picker", lambda: (a := session.agent()) and a.get("prompt") and a["prompt"]["kind"] == "question" and a)
    questions = agent["prompt"]["questions"]
    options = pick(questions)
    session.call("phone.answer", {"pane": pane, "prompt": agent["prompt"]["id"], "answer": {"options": options}})
    expected = "; ".join(", ".join(q["options"][i]["label"] for i in chosen) for q, chosen in zip(questions, options))
    session.wait(
        f"the answer {expected!r}",
        lambda: any(e["kind"] == "question" and e.get("answer") == expected for e in session.entries()),
    )
    session.wait("the agent to finish", lambda: (a := session.agent()) and not a.get("prompt") and a["state"] != "working")
    return expected


step("a picker with two questions is answered from the phone")
print("   answered " + answer_question(
    "Use AskUserQuestion once with two questions: first, color (red or blue); second, size (small or large). Then stop.",
    lambda questions: [[1] for _ in questions],
))

step("a multiple choice is answered from the phone")
print("   answered " + answer_question(
    "Use AskUserQuestion with one multiSelect question: which fruits (apple, pear, plum). Then stop.",
    lambda questions: [[0, len(q["options"]) - 1] if q["multiSelect"] else [0] for q in questions],
))

step("a Bash permission prompt is allowed from the phone")
session.call("phone.reply", {"pane": pane, "text": "Run this exact shell command with the Bash tool: touch allowed.txt"})
agent = session.wait("the permission prompt", lambda: (a := session.agent()) and a.get("prompt") and a["prompt"]["kind"] == "permission" and a)
print(f"   inbox: {agent['lastLine']}")
session.call("phone.answer", {"pane": pane, "prompt": agent["prompt"]["id"], "answer": {"allow": True}})
session.wait("allowed.txt", lambda: os.path.exists(os.path.join(folder, "allowed.txt")), 60)
session.wait("the agent to finish", lambda: (a := session.agent()) and a["state"] == "done")
if not any(e["kind"] == "tools" and "touch allowed.txt" in e["text"] and not e["failed"] for e in session.entries()):
    fail("the transcript does not show the allowed command")

step("a stale answer is refused, and a denial sends Escape")
session.call("phone.reply", {"pane": pane, "text": "Run this exact shell command with the Bash tool: touch denied.txt"})
agent = session.wait("the second permission prompt", lambda: (a := session.agent()) and a.get("prompt") and a["prompt"]["kind"] == "permission" and a)
try:
    session.call("phone.answer", {"pane": pane, "prompt": "not-this-one", "answer": {"allow": True}})
    fail("a stale answer was taken")
except RuntimeError as error:
    if "prompt_gone" not in str(error):
        fail(f"a stale answer failed with {error}")
session.call("phone.answer", {"pane": pane, "prompt": agent["prompt"]["id"], "answer": {"allow": False}})
session.wait("the denial", lambda: (a := session.agent()) and not a.get("prompt") and a["state"] != "waiting", 60)
time.sleep(2)
if os.path.exists(os.path.join(folder, "denied.txt")):
    fail("denied.txt exists")
print("   denied.txt was not created")

print("\nphone-claude-e2e passed")
