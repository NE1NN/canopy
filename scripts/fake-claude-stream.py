#!/usr/bin/env python3
"""A stand-in for `claude -p --input-format stream-json --output-format stream-json`, for chat tab tests and fixtures.

It takes Claude Code's arguments (`--model`, `--permission-mode`, `--resume`, `--replay-user-messages`; the rest are
ignored), answers `initialize`, `set_permission_mode`, and `interrupt`, writes its conversation to
$HOME/.claude/projects/<folder>/<session>.jsonl as Claude Code does, and reports through `$CANOPY_CLI agent-hook`.

What it does with a message depends on how the message starts:
  say <text>     streams <text> a word at a time, then ends the turn
  run <command>  asks to run <command> with Bash, then says whether it ran
  ask            asks a question with AskUserQuestion
  slow [<n>]     streams <n> words (default 200) as one paragraph, stopping early if interrupted
  prose [<n>]    streams <n> words (default 600) in paragraphs of 60, as a reply reads
  markdown [<n>] streams a reply with every kind of block; with <n>, holds the turn open after <n> words until an
                 interrupt, so a block can be looked at while it grows
  pause [<n>]    streams one word, then holds the turn open until <n> more messages (default 1) wait, or an
                 interrupt
  hold           asks to run `make test` and never ends the turn on its own
  crash          writes to stderr and exits 1
  /clear         starts a new session, as Claude Code's /clear does
  tail [hold]    runs a command that prints ten lines over two seconds, written to its task file as Claude Code does
  agent          runs a subagent that makes three tool calls of its own
  plan           proposes a plan with ExitPlanMode, then says how it was answered
  two            asks two permissions at once, as parallel subagents do, and waits for both
  callback       sends a control request Canopy does not handle, then says how it was answered
  artifact [<t>] publishes an artifact titled <t> (default "Canopy Board"), one version higher each time
  anything else  answers "You said: <message>"
FAKE_CLAUDE_DELAY sets the seconds between streamed words (default 0.01), and FAKE_CLAUDE_VERSION the version it
reports (default 2.1.296).
"""
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone

args = sys.argv[1:]


def option(name, default=None):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else default


MODEL = option("--model", "claude-sonnet-5-5")
mode = option("--permission-mode", "default")
SESSION = option("--resume") or str(uuid.uuid4())
VERSION = os.environ.get("FAKE_CLAUDE_VERSION", "2.1.296")
REPLAY = "--replay-user-messages" in args
DELAY = float(os.environ.get("FAKE_CLAUDE_DELAY", "0.01"))
CWD = os.getcwd()
PROJECTS = os.path.join(os.environ.get("HOME") or tempfile.gettempdir(), ".claude", "projects",
                        "".join(c if c.isalnum() else "-" for c in CWD))
TRANSCRIPT = os.path.join(PROJECTS, SESSION + ".jsonl")


def start_session(session):
    global SESSION, TRANSCRIPT
    SESSION = session
    TRANSCRIPT = os.path.join(PROJECTS, SESSION + ".jsonl")

out_lock = threading.Lock()
responses = {}
responses_lock = threading.Condition()
messages = queue.Queue()
interrupted = threading.Event()


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def emit(obj):
    obj.setdefault("session_id", SESSION)
    with out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def record(kind, content, **extra):
    """Writes a transcript line and returns it as a stream message."""
    line = {"type": kind, "message": {"role": kind, "content": content}, "uuid": str(uuid.uuid4()),
            "timestamp": now(), "sessionId": SESSION, "isSidechain": False, "cwd": CWD, "entrypoint": "sdk-cli"}
    line.update(extra)
    os.makedirs(PROJECTS, exist_ok=True)
    with open(TRANSCRIPT, "a") as file:
        file.write(json.dumps(line) + "\n")
    message = {"type": kind, "message": line["message"], "parent_tool_use_id": None, "uuid": line["uuid"]}
    if kind == "assistant":
        message["message"]["usage"] = {"input_tokens": 3, "cache_creation_input_tokens": 1000,
                                       "cache_read_input_tokens": 20000, "output_tokens": 40}
    return message


def hook(event, **fields):
    cli = os.environ.get("CANOPY_CLI")
    if not cli:
        return
    payload = {"session_id": SESSION, "transcript_path": TRANSCRIPT, "cwd": CWD, "hook_event_name": event}
    payload.update(fields)
    try:
        subprocess.run([cli, "agent-hook"], input=json.dumps(payload).encode(), timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def ask(tool, tool_input, needs_author=False):
    """Sends a can_use_tool request and waits for its answer."""
    request_id = str(uuid.uuid4())
    tool_id = "toolu_" + uuid.uuid4().hex[:20]
    emit(record("assistant", [{"type": "tool_use", "id": tool_id, "name": tool, "input": tool_input}]))
    hook("PermissionRequest", tool_name=tool, tool_input=tool_input)
    request = {"subtype": "can_use_tool", "tool_name": tool, "display_name": tool, "input": tool_input,
               "tool_use_id": tool_id, "permission_suggestions": []}
    if tool == "Bash":
        request["description"] = tool_input.get("description", "")
        request["permission_suggestions"] = [{"type": "addRules", "rules": [
            {"toolName": "Bash", "ruleContent": tool_input["command"].split(" ")[0] + ":*"}],
            "behavior": "allow", "destination": "localSettings"}]
    if needs_author:
        request["requires_user_interaction"] = True
    emit({"type": "control_request", "request_id": request_id, "request": request})
    with responses_lock:
        # As Claude Code 2.1.296 does, an interrupt does not answer a permission request: it waits on.
        while request_id not in responses:
            responses_lock.wait(0.1)
        answer = responses.pop(request_id, None)
    return tool_id, answer


MARKDOWN = (
    "## Streaming check\n\nHere is **bold text**, some *italic words*, a bit of `inline code`, and a "
    "[link](https://example.com) inside a paragraph that runs long enough to wrap across more than one line of "
    "the column, as Claude's replies often do when they explain something.\n\n"
    "1. First step with `make app`\n2. Second step, which is a longer item so that it wraps onto a second line in "
    "the column when the window is narrow enough\n3. Third\n\n"
    "- A bullet with **bold**\n  - A nested bullet\n- Another bullet\n\n"
    "> A quoted line that Claude might write when citing something it read.\n\n"
    "```swift\nlet greeting = \"Hello\"\nfor name in [\"Ann\", \"Bo\"] {\n    print(greeting, name)\n}\n```\n\n"
    "### Done\n\nThat is every kind of block."
)


def stream(text, hold_after=None):
    message_id = "msg_" + uuid.uuid4().hex[:12]
    emit({"type": "stream_event", "event": {"type": "message_start", "message": {"id": message_id}}})
    emit({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
                                            "content_block": {"type": "text", "text": ""}}})
    words = text.split(" ")
    for index, word in enumerate(words):
        if interrupted.is_set():
            return False
        emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                "delta": {"type": "text_delta",
                                                          "text": word + (" " if index < len(words) - 1 else "")}}})
        emit({"type": "stream_event", "event": {"type": "message_delta", "delta": {},
                                                "usage": {"output_tokens": index + 1}}})
        time.sleep(DELAY)
        if hold_after is not None and index + 1 == hold_after:
            deadline = time.time() + 600
            while not interrupted.is_set() and time.time() < deadline:
                time.sleep(0.02)
    emit(record("assistant", [{"type": "text", "text": text}]))
    return True


def finish(text, error=False):
    if interrupted.is_set():
        emit(record("user", [{"type": "text", "text": "[Request interrupted by user]"}]))
        emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "num_turns": 1})
    else:
        emit({"type": "result", "subtype": "success", "is_error": error, "result": text, "num_turns": 1,
              "modelUsage": {MODEL: {"contextWindow": 1000000, "outputTokens": 40}}})
    hook("Stop", last_assistant_message=text)


# Publishes per artifact URL in this process, for their versions.
published = {}


def turn(text):
    global mode
    interrupted.clear()
    if text == "/clear":
        old = SESSION
        start_session(str(uuid.uuid4()))
        emit({"type": "conversation_reset", "new_conversation_id": SESSION, "trigger": "clear", "session_id": old})
    emit({"type": "system", "subtype": "init", "session_id": SESSION, "model": MODEL, "permissionMode": mode,
          "cwd": CWD, "slash_commands": ["compact", "clear", "context"], "tools": ["Bash"],
          "claude_code_version": VERSION})
    if text == "/clear":
        emit({"type": "result", "subtype": "success", "is_error": False, "result": "", "num_turns": 0})
        return
    emit({"type": "system", "subtype": "status", "status": "requesting"})
    hook("UserPromptSubmit", prompt=text)
    if text.startswith("say "):
        said = text[4:]
        stream(said)
        finish(said)
    elif text.startswith("run ") or text == "hold":
        command = text[4:] if text != "hold" else "make test"
        tool_id, answer = ask("Bash", {"command": command, "description": "Run " + command})
        if text == "hold" and answer is None:
            finish("")
            return
        if answer and answer.get("behavior") == "allow":
            emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": "ran " + command,
                                  "is_error": False}]))
            hook("PostToolUse", tool_name="Bash")
            stream("It ran.")
            finish("It ran.")
        else:
            message = (answer or {}).get("message", "The user doesn't want to proceed with this tool use.")
            emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": message,
                                  "is_error": True}]))
            stream("I did not run it.")
            finish("I did not run it.")
    elif text == "artifact" or text.startswith("artifact "):
        # As Claude Code 2.1.296 publishes: a tool call, then its result with the page's details.
        title = text[9:] or "Canopy Board"
        slug = "".join(c for c in title.title() if c.isalnum())
        url = "https://claude.ai/artifact/Fake" + slug
        published[url] = published.get(url, 0) + 1
        version = published[url]
        tool_id = "toolu_" + uuid.uuid4().hex[:20]
        path = "/tmp/" + slug.lower() + "/index.html"
        emit(record("assistant", [{"type": "tool_use", "id": tool_id, "name": "Artifact",
                                   "input": {"file_path": path, "icon": "board"}}]))
        details = {"url": url, "path": path, "artifact_id": "fake-" + slug.lower(), "title": title,
                   "updated": version > 1, "icon": "board", "audience": "owner", "seq": version,
                   "version": "%d-a" % version}
        content = "Published %s at %s (Version %d, version id %d-a)" % (path, url, version, version)
        message = record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": content}],
                         toolUseResult=details)
        message["tool_use_result"] = details
        emit(message)
        stream("It's open beside this chat.")
        finish("It's open beside this chat.")
    elif text == "ask":
        questions = [{"question": "Which color?", "header": "Color", "multiSelect": False,
                      "options": [{"label": "Blue (Recommended)", "description": "Calm"},
                                  {"label": "Red", "description": "Loud"}]}]
        tool_id, answer = ask("AskUserQuestion", {"questions": questions}, needs_author=True)
        if answer and answer.get("behavior") == "allow":
            chosen = answer.get("updatedInput", {}).get("answers", {})
            content = "Your questions have been answered: " + ", ".join(
                '"%s"="%s"' % pair for pair in chosen.items())
            emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": content}]))
            finish(content)
        else:
            message = (answer or {}).get("message", "declined")
            emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": message,
                                  "is_error": True}]))
            finish(message)
    elif text == "pause" or text.startswith("pause "):
        waiting = int(text[6:]) if text.startswith("pause ") else 1
        stream("Waiting.")
        deadline = time.time() + 120
        while messages.qsize() < waiting and not interrupted.is_set() and time.time() < deadline:
            time.sleep(0.02)
        finish("Waited.")
    elif text == "slow" or text.startswith("slow "):
        count = int(text[5:]) if text.startswith("slow ") else 200
        stream(" ".join(["word%d" % i for i in range(count)]))
        finish("slow")
    elif text == "markdown" or text.startswith("markdown "):
        stream(MARKDOWN, int(text[9:]) if text.startswith("markdown ") else None)
        finish("markdown")
    elif text == "prose" or text.startswith("prose "):
        count = int(text[6:]) if text.startswith("prose ") else 600
        words = ["word%d" % i for i in range(count)]
        stream("\n\n".join(" ".join(words[i:i + 60]) for i in range(0, count, 60)))
        finish("prose")
    elif text == "tail" or text == "tail hold":
        tool_id, task = "toolu_" + uuid.uuid4().hex[:20], "b" + uuid.uuid4().hex[:8]
        emit(record("assistant", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {"command": "count"}}]))
        root = os.environ.get("FAKE_CLAUDE_TASKS", "/tmp/claude-%d" % os.getuid())
        folder = os.path.join(root, "".join(c if c.isalnum() else "-" for c in CWD), SESSION, "tasks")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, task + ".output")
        emit({"type": "system", "subtype": "task_started", "task_id": task, "tool_use_id": tool_id,
              "is_backgrounded": False, "task_type": "local_bash"})
        with open(path, "w") as out:
            for n in range(1, 11):
                out.write("line %d\n" % n)
                out.flush()
                time.sleep(0.2)
        if text == "tail hold":
            # Runs until the next message comes, so a test decides when it ends.
            deadline = time.time() + 120
            while messages.qsize() < 1 and time.time() < deadline:
                time.sleep(0.05)
        else:
            time.sleep(0.5)
        os.remove(path)
        emit({"type": "system", "subtype": "task_notification", "task_id": task, "tool_use_id": tool_id,
              "status": "completed"})
        emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": "line 10"}]))
        finish("counted")
    elif text == "agent":
        tool_id = "toolu_" + uuid.uuid4().hex[:20]
        emit(record("assistant", [{"type": "tool_use", "id": tool_id, "name": "Agent",
                                   "input": {"description": "Look around", "prompt": "Look"}}]))
        for n in range(3):
            inner = {"type": "assistant", "uuid": str(uuid.uuid4()), "parent_tool_use_id": tool_id,
                     "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "toolu_in%d" % n,
                                                                   "name": "Read", "input": {"file_path": "/x"}}]}}
            emit(inner)
        emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": "looked"}]))
        finish("looked")
    elif text == "plan":
        tool_id, answer = ask("ExitPlanMode", {"plan": "# Plan\n\n1. Add the case\n2. Save it"}, needs_author=True)
        if answer and answer.get("behavior") == "allow":
            for update in answer.get("updatedPermissions", []):
                if update.get("type") == "setMode":
                    mode = update.get("mode", mode)
                    emit({"type": "system", "subtype": "status", "status": None, "permissionMode": mode})
            emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": "User has approved your plan."}]))
            stream("Approved in " + mode + ".")
            finish("Approved in " + mode + ".")
        else:
            emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id, "content": "declined", "is_error": True}]))
            finish("Kept planning.")
    elif text == "two":
        asked = []
        for command in ("ls a", "ls b"):
            request_id, tool_id = str(uuid.uuid4()), "toolu_" + uuid.uuid4().hex[:20]
            emit(record("assistant", [{"type": "tool_use", "id": tool_id, "name": "Bash",
                                       "input": {"command": command}}]))
            emit({"type": "control_request", "request_id": request_id, "request": {
                "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": command},
                "tool_use_id": tool_id, "permission_suggestions": []}})
            asked.append((request_id, tool_id))
        for request_id, tool_id in asked:
            with responses_lock:
                while request_id not in responses:
                    responses_lock.wait(0.1)
                answer = responses.pop(request_id)
            allowed = answer.get("behavior") == "allow"
            emit(record("user", [{"type": "tool_result", "tool_use_id": tool_id,
                                  "content": "ran" if allowed else "denied", "is_error": not allowed}]))
        stream("Both answered.")
        finish("Both answered.")
    elif text == "callback":
        request_id = str(uuid.uuid4())
        emit({"type": "control_request", "request_id": request_id, "request": {"subtype": "mcp_message"}})
        with responses_lock:
            while request_id not in responses:
                responses_lock.wait(0.1)
            answer = responses.pop(request_id)
        said = "answered: " + answer.get("message", "")
        stream(said)
        finish(said)
    elif text == "crash":
        sys.stderr.write("boom: something broke\n")
        sys.stderr.flush()
        os._exit(1)
    else:
        said = "You said: " + text
        stream(said)
        finish(said)


def text_of(message):
    content = message.get("message", {}).get("content")
    if isinstance(content, str):
        return content
    # A `!` command's block goes ahead of the message; what the stand-in acts on is the message itself.
    return " ".join(block.get("text", "") for block in content or []
                    if block.get("type") == "text" and not block.get("text", "").startswith(("<bash-", "<shell-run")))


def has_bash_tags(message):
    content = message.get("message", {}).get("content")
    blocks = [content] if isinstance(content, str) else [b.get("text", "") for b in content or []]
    return any("<bash-" in block for block in blocks)


def worker():
    while True:
        message = messages.get()
        if message is None:
            return
        # As Claude Code does, messages that queued up during a turn go in together as one message.
        while not messages.empty():
            more = messages.get()
            if more is None:
                messages.put(None)
                break
            message = merged(message, more)
        text = text_of(message)
        written = record("user", message.get("message", {}).get("content", text))
        # Claude Code 2.1.296 replays no message holding `<bash-…>` tags.
        if REPLAY and not has_bash_tags(message):
            replay = dict(message)
            replay.update({"uuid": written["uuid"], "isReplay": True, "session_id": SESSION})
            emit(replay)
        turn(text)


def blocks(message):
    content = message.get("message", {}).get("content")
    return [{"type": "text", "text": content}] if isinstance(content, str) else list(content or [])


def merged(first, second):
    combined = dict(first)
    combined["message"] = {"role": "user", "content": blocks(first) + blocks(second)}
    return combined


def main():
    global mode
    hook("SessionStart", source="resume" if option("--resume") else "startup")
    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            line = json.loads(raw)
        except ValueError:
            continue
        kind = line.get("type")
        if kind == "user":
            messages.put(line)
        elif kind == "control_request":
            request = line.get("request", {})
            subtype = request.get("subtype")
            reply = {"type": "control_response", "response": {"subtype": "success",
                                                              "request_id": line.get("request_id")}}
            if subtype == "initialize":
                reply["response"]["response"] = {"commands": [
                    {"name": "compact", "description": "Clear history but keep a summary", "argumentHint": ""},
                    {"name": "greet", "description": "Say the greeting (project)", "argumentHint": "<name>"}],
                    "models": [{"value": "sonnet", "displayName": "Sonnet"}]}
            elif subtype == "set_permission_mode":
                mode = request.get("mode", mode)
                reply["response"]["response"] = {"mode": mode}
                emit({"type": "system", "subtype": "status", "status": None, "permissionMode": mode})
            elif subtype == "interrupt":
                interrupted.set()
                with responses_lock:
                    responses_lock.notify_all()
                reply["response"]["response"] = {"still_queued": []}
            else:
                reply["response"] = {"subtype": "error", "request_id": line.get("request_id"),
                                     "error": "Unsupported control request: %s" % subtype}
            emit(reply)
        elif kind == "control_response":
            response = line.get("response", {})
            with responses_lock:
                responses[response.get("request_id")] = response.get("response") or {
                    "behavior": "deny", "message": response.get("error", "error")}
                responses_lock.notify_all()
    messages.put(None)
    thread.join(timeout=30)
    hook("SessionEnd")


main()
