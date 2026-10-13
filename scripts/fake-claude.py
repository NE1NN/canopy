#!/usr/bin/env python3
"""A stand-in Claude Code for the phone fixture: it draws a Claude-like screen, writes its conversation in Claude
Code's transcript format, and reports to Canopy through `canopy agent-hook` as Claude Code's hooks do.

  fake-claude.py <canopy-cli> <scenario> <transcript-file> [<option>...] [<brief>]

Run it in a pane, which sets CANOPY_PANE. It answers the phone the way Claude Code would: a reply (a bracketed paste,
then Return) becomes the next prompt, a digit answers its question, and Return allows its command.
Scenarios: main, companion, drain, labels, lost, ticket, migrate for a box, and task, which starts on the brief that
New task on the phone passes as the last argument.
"""
import json
import os
import subprocess
import sys
import termios
import threading
import time
import tty
import uuid
from datetime import datetime, timezone

CLI, SCENARIO, TRANSCRIPT = sys.argv[1:4]
# The brief comes last, after whatever options the agent command passes.
BRIEF = sys.argv[-1] if len(sys.argv) > 4 else ""
SESSION = str(uuid.uuid4())
CWD = os.getcwd()
lock = threading.Lock()

DIM, BOLD, RESET = "\x1b[2m", "\x1b[1m", "\x1b[0m"
BLUE, YELLOW, GREEN, GREY = "\x1b[34m", "\x1b[33m", "\x1b[32m", "\x1b[90m"


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def line(kind, content):
    return {"type": kind, "message": {"role": kind, "content": content}, "uuid": str(uuid.uuid4()),
            "timestamp": now(), "sessionId": SESSION, "isSidechain": False, "cwd": CWD}


def write(*entries):
    with lock, open(TRANSCRIPT, "a") as file:
        for entry in entries:
            file.write(json.dumps(entry) + "\n")


def prompt(text):
    return line("user", text)


def say(text):
    return line("assistant", [{"type": "text", "text": text}])


def tool(name, tool_input, tool_id=None):
    return line("assistant", [{"type": "tool_use", "id": tool_id or "toolu_" + uuid.uuid4().hex[:20],
                               "name": name, "input": tool_input}])


def result(tool_id, text, error=False):
    return line("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": text, "is_error": error}])


def ran(name, tool_input, text="Done."):
    tool_id = "toolu_" + uuid.uuid4().hex[:20]
    return [tool(name, tool_input, tool_id), result(tool_id, text)]


def hook(event, **fields):
    payload = {"session_id": SESSION, "hook_event_name": event, "transcript_path": TRANSCRIPT, "cwd": CWD, **fields}
    subprocess.run([CLI, "agent-hook"], input=json.dumps(payload).encode(), check=False)


def draw(*lines):
    sys.stdout.write("\r\n".join(lines) + "\r\n")
    sys.stdout.flush()


QUESTION = {"question": "Should the phone reach the Mac through Tailscale or a Cloudflare tunnel?",
            "header": "Transport", "multiSelect": False,
            "options": [{"label": "Tailscale", "description": "Private to your devices."},
                        {"label": "Tunnel", "description": "No app on the phone, but public behind a login."}]}
DEPLOY = {"command": "npx convex deploy", "description": "Deploy the usage fix to Convex"}
state = {"question": None, "permission": None}


def start():
    if SCENARIO == "main":
        write(prompt("Watch the rows and tell me when one is ready to merge."),
              *ran("Bash", {"command": "canopy term list --all"}),
              *ran("Read", {"file_path": f"{CWD}/docs/rows.md"}),
              say("Watching 6 rows. #41 is ready to merge."))
        hook("UserPromptSubmit", prompt="Watch the rows")
        draw(f"{DIM}⏺ Bash(canopy term list --all){RESET}", f"{DIM}  ⎿  6 rows{RESET}", "",
             f"{BLUE}⏺{RESET} Watching 6 rows. #41 is ready to merge.", "", f"{GREY}✻ Watching… (esc to interrupt){RESET}")
    elif SCENARIO == "companion":
        reads = [entry for name in ["ControlServer.swift", "ControlClient.swift", "PhoneListener.swift", "Wire.swift"]
                 for entry in ran("Read", {"file_path": f"{CWD}/Sources/{name}"})]
        tool_id = "toolu_question"
        state["question"] = tool_id
        write(prompt("Draft the transport for the phone app. Keep the Mac's socket private."), *reads,
              *ran("Bash", {"command": "make test"}, "412 passed"),
              say("The phone can reuse the control methods the CLI already speaks: term list, term read, term send, "
                  "term wait. It needs a way in from outside your network."),
              tool("AskUserQuestion", {"questions": [QUESTION]}, tool_id))
        hook("UserPromptSubmit", prompt="Draft the transport")
        hook("PreToolUse", tool_name="AskUserQuestion", tool_input={"questions": [QUESTION]})
        hook("PermissionRequest", tool_name="AskUserQuestion", tool_input={"questions": [QUESTION]})
        hook("Notification", notification_type="permission_prompt", message="Claude needs your permission")
        draw(f"{DIM}⏺ Read 4 files (ctrl+o to expand){RESET}", f"{DIM}⏺ Bash(make test){RESET}",
             f"{DIM}  ⎿  412 passed{RESET}", "",
             f"{BLUE}⏺{RESET} The phone can reuse the control methods the CLI already speaks: term list, term read,",
             "  term send, term wait. It needs a way in from outside your network.", "",
             f"{GREY}────────────────────────────────────────────────────────────────────────────────{RESET}",
             f" {BOLD}☐ Transport{RESET}", "",
             "Should the phone reach the Mac through Tailscale or a Cloudflare tunnel?", "",
             f"{BLUE}❯ 1. Tailscale{RESET}", f"{DIM}     Private to your devices.{RESET}", "  2. Tunnel",
             f"{DIM}     No app on the phone, but public behind a login.{RESET}", "  3. Type something.", "",
             f"{GREY}Enter to select · ↑/↓ to navigate · Esc to cancel{RESET}")
    elif SCENARIO == "drain":
        write(prompt("Fix the port scan drain and open a PR."),
              *ran("Edit", {"file_path": f"{CWD}/Sources/PortScanner.swift"}),
              *ran("Bash", {"command": "make test"}, "418 passed"),
              *ran("Bash", {"command": "gh pr create --fill"}),
              say("The scan reads sockets through the sysctl now, so nothing drains them.\n\nREADY: PR #41 open, CI green"))
        hook("UserPromptSubmit", prompt="Fix the drain")
        hook("Stop", last_assistant_message="READY: PR #41 open, CI green")
        draw(f"{BLUE}⏺{RESET} The scan reads sockets through the sysctl now, so nothing drains them.", "",
             f"  {GREEN}READY:{RESET} PR #41 open, CI green", "", f"{GREY}>{RESET} ")
    elif SCENARIO == "labels":
        write(prompt("Label each port with its Convex deployment."),
              *ran("Edit", {"file_path": f"{CWD}/Sources/PortLabels.swift"}),
              *ran("Edit", {"file_path": f"{CWD}/Sources/PortsView.swift"}),
              tool("Bash", {"command": "make test"}))
        hook("UserPromptSubmit", prompt="Label each port")
        draw(f"{DIM}⏺ Update(Sources/PortLabels.swift){RESET}", f"{DIM}⏺ Update(Sources/PortsView.swift){RESET}",
             f"{BLUE}⏺{RESET} Bash(make test)", f"{DIM}  ⎿  Running…{RESET}", "", f"{GREY}✻ Testing… (esc to interrupt){RESET}")
    elif SCENARIO == "lost":
        write(prompt("Find why the control server drops requests under load."),
              *ran("Bash", {"command": "scripts/e2e.sh", "run_in_background": True}, "Started in the background."),
              say("The e2e run is going in the background. I'll look at its log when it ends."))
        hook("UserPromptSubmit", prompt="Find why")
        hook("Stop", last_assistant_message="The e2e run is going in the background.",
             background_tasks=[{"id": "b1", "type": "shell", "status": "running", "description": "scripts/e2e.sh",
                                "command": "scripts/e2e.sh"}])
        draw(f"{BLUE}⏺{RESET} The e2e run is going in the background. I'll look at its log when it ends.", "",
             f"{GREY}  ⏵⏵ 1 background task{RESET}")
    elif SCENARIO == "migrate":
        write(prompt("Run the usage migration on staging and check the totals."),
              *ran("Bash", {"command": "npm run migrate -- --env staging"}, "Migrated 48,210 rows."),
              *ran("Bash", {"command": "npm run check:usage"}, "Totals match."),
              say("The migration ran on staging and the totals match.\n\nREADY: staging migrated, totals match"))
        hook("UserPromptSubmit", prompt="Run the migration")
        hook("Stop", last_assistant_message="READY: staging migrated, totals match")
        draw(f"{BLUE}⏺{RESET} The migration ran on staging and the totals match.", "",
             f"  {GREEN}READY:{RESET} staging migrated, totals match", "", f"{GREY}>{RESET} ")
    elif SCENARIO == "task":
        write(prompt(BRIEF), *ran("Read", {"file_path": f"{CWD}/README.md"}))
        hook("UserPromptSubmit", prompt=BRIEF)
        draw(f"{DIM}⏺ Read(README.md){RESET}", "", f"{GREY}✻ Reading… (esc to interrupt){RESET}")
        threading.Thread(target=finish, args=("Read the usage page. The health check goes next to the totals.",)).start()
    elif SCENARIO == "ticket":
        tool_id = "toolu_deploy"
        state["permission"] = tool_id
        write(prompt("Fix #0853: the usage page shows stale totals."),
              *ran("Edit", {"file_path": f"{CWD}/convex/usage.ts"}),
              say("The totals were cached for a day. They are computed on read now. Deploying it."),
              tool("Bash", DEPLOY, tool_id))
        hook("UserPromptSubmit", prompt="Fix #0853")
        hook("PermissionRequest", tool_name="Bash", tool_input=DEPLOY)
        hook("Notification", notification_type="permission_prompt", message="Claude needs your permission to use Bash")
        draw(f"{BLUE}⏺{RESET} The totals were cached for a day. They are computed on read now. Deploying it.", "",
             f"{GREY}──────────────────────────────────────────────────────────────────{RESET}",
             f" {BOLD}Bash command{RESET}", "", "   npx convex deploy", f"{DIM}   Deploy the usage fix to Convex{RESET}", "",
             " Do you want to proceed?", f" {BLUE}❯ 1. Yes{RESET}", "   2. Yes, and don't ask again for npx convex",
             "   3. No, and tell Claude what to do differently (esc)")


def finish(text):
    time.sleep(1.5)
    write(say(text))
    hook("Stop", last_assistant_message=text)
    draw("", f"{BLUE}⏺{RESET} {text}", "", f"{GREY}>{RESET} ")


def answered(tool_id, answer):
    write(result(tool_id, f'Your questions have been answered: "{QUESTION["question"]}"="{answer}". '
                          "You can now continue with these answers in mind."))
    hook("PostToolUse", tool_name="AskUserQuestion",
         tool_input={"questions": [QUESTION], "answers": {QUESTION["question"]: answer}})
    draw("", f"{DIM}⏺ User answered: {answer}{RESET}")
    finish(f"Going with {answer}. I'll draft the listener next.")


def allowed(tool_id):
    write(result(tool_id, "Deployed to happy-otter-123."))
    hook("PostToolUse", tool_name="Bash", tool_input=DEPLOY)
    draw("", f"{BLUE}⏺{RESET} Bash(npx convex deploy)", f"{DIM}  ⎿  Deployed to happy-otter-123.{RESET}")
    finish("Deployed. The usage page shows fresh totals now.")


def replied(text):
    write(prompt(text))
    hook("UserPromptSubmit", prompt=text)
    draw("", f"{GREY}>{RESET} {text.splitlines()[0] if text else ''}")
    first = text.strip().splitlines()[0] if text.strip() else ""
    finish(f"On it: {first}")


def listen():
    pasted, in_paste, buffer = "", False, ""
    while True:
        data = os.read(0, 4096).decode(errors="replace")
        if not data:
            return
        buffer += data
        while buffer:
            if buffer.startswith("\x1b[200~"):
                in_paste, buffer = True, buffer[6:]
                continue
            if buffer.startswith("\x1b[201~"):
                in_paste, buffer = False, buffer[6:]
                continue
            if in_paste:
                end = buffer.find("\x1b[201~")
                pasted += buffer if end < 0 else buffer[:end]
                buffer = "" if end < 0 else buffer[end:]
                continue
            key, buffer = buffer[0], buffer[1:]
            if key == "\x1b" and buffer.startswith("["):
                buffer = buffer[2:]
                continue
            # Taken here, before the worker starts, so a key pressed twice answers once.
            if state["question"] and key in "12":
                tool_id, state["question"] = state["question"], None
                threading.Thread(target=answered, args=(tool_id, QUESTION["options"][int(key) - 1]["label"])).start()
            elif state["permission"] and key == "\r":
                tool_id, state["permission"] = state["permission"], None
                threading.Thread(target=allowed, args=(tool_id,)).start()
            elif state["permission"] and key == "\x1b":
                state["permission"] = None
                draw("", f"{YELLOW}Interrupted · What should Claude do instead?{RESET}")
            elif key == "\r" and pasted:
                text, pasted = pasted.replace("\r", "\n"), ""
                threading.Thread(target=replied, args=(text,)).start()


def main():
    open(TRANSCRIPT, "a").close()
    hook("SessionStart", source="startup")
    start()
    attributes = termios.tcgetattr(0)
    try:
        tty.setraw(0)
        listen()
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, attributes)


if __name__ == "__main__":
    main()
