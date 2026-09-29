#!/usr/bin/env python3
"""A stand-in for ticket-manager's read-only API, for end-to-end runs and UI checks. Nothing here reaches a real
ticket-manager deployment or Discord.

    ticket-manager-stand-in.py seed --fixtures <dir> --out <dir> [--ui]
        Writes a data folder from ticket-manager's response fixtures: me.json, tickets.json with every ticket, and
        details/<id>.json. --ui adds tickets for UI checks, with long messages, markdown, images, one too big to
        show, an expired attachment, threads, and a closed ticket, and cdn/ with their images, made from this Mac's
        own pictures.

    ticket-manager-stand-in.py serve --data <dir> --token <token> [--not-staff-token <token>] [--port <n>]
            [--port-file <file>] [--log <file>] [--lifetime <seconds>]
        Serves the API on 127.0.0.1, reading the data folder on every request, so a test changes what it answers by
        editing the files. It answers as ticket-manager does: 401 with a Bearer challenge without the token, 403 for
        --not-staff-token, 400 for a malformed id, and a JSON 404 for other paths and methods. Discord CDN links point
        at its own /cdn/, which serves the data folder's cdn/ by file name. It gives up after --lifetime seconds,
        1800 by default, so a run that dies never leaves it behind.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CDN = "https://cdn.discordapp.com/"
ID = re.compile(r"[0-9a-z]{32}")
STATUSES = ("open", "closed", "archived")


def error(code, message):
    return {"error": {"code": code, "message": message}}


def load(path, fallback=None):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return fallback


def save(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")


# Serving


def serve(args):
    data = args.data
    log = open(args.log, "a", buffering=1) if args.log else None

    class Handler(BaseHTTPRequestHandler):
        server_version = "ticket-manager-stand-in"

        def log_message(self, format, *values):
            if log:
                log.write("%s %s\n" % (self.command, self.path))

        def reply(self, status, body, headers=None):
            port = self.server.server_address[1]
            text = json.dumps(body).replace(CDN, "http://127.0.0.1:%d/cdn/" % port)
            payload = text.encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(payload)

        def not_found(self):
            self.reply(404, error("not_found", "No route for %s %s" % (self.command, self.path)))

        do_POST = do_PUT = do_PATCH = do_DELETE = not_found

        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            if url.path.startswith("/cdn/"):
                return self.cdn(url.path)
            if not url.path.startswith("/api/v1/"):
                return self.not_found()
            auth = self.headers.get("Authorization", "")
            if args.not_staff_token and auth == "Bearer " + args.not_staff_token:
                return self.reply(403, error("not_staff", "gone@example.com is not on the staff list"))
            if auth != "Bearer " + args.token:
                return self.reply(
                    401, error("unauthorized", "Send Authorization: Bearer <token>"), {"WWW-Authenticate": "Bearer"})
            route = url.path[len("/api/v1/"):]
            query = urllib.parse.parse_qs(url.query)
            tickets = load(os.path.join(data, "tickets.json"), {"tickets": []})["tickets"]
            if route == "me":
                return self.reply(200, load(os.path.join(data, "me.json")))
            if route == "tickets":
                return self.list(tickets, query)
            if route.startswith("tickets/"):
                return self.detail(tickets, urllib.parse.unquote(route[len("tickets/"):]))
            self.not_found()

        def list(self, tickets, query):
            if "ids" in query and "status" in query:
                return self.reply(400, error("bad_request", "Pass status or ids, not both"))
            if "ids" in query:
                ids = [i for i in ",".join(query["ids"]).split(",") if i]
                if len(ids) > 50:
                    return self.reply(400, error("bad_request", "At most 50 ids"))
                bad = [i for i in ids if not ID.fullmatch(i)]
                if bad:
                    return self.reply(400, error("bad_request", "Malformed ticket id: %s" % bad[0]))
                by_id = {t["id"]: t for t in tickets}
                return self.reply(200, {"tickets": [by_id[i] for i in ids if i in by_id]})
            status = query.get("status", ["open"])[0]
            if status not in STATUSES:
                return self.reply(400, error("bad_request", "status must be open, closed, or archived"))
            listed = sorted((t for t in tickets if t["status"] == status), key=lambda t: -t["lastActivityAt"])
            self.reply(200, {"tickets": listed})

        def detail(self, tickets, ticket_id):
            if not ID.fullmatch(ticket_id):
                return self.reply(400, error("bad_request", "Malformed ticket id: %s" % ticket_id))
            summary = next((t for t in tickets if t["id"] == ticket_id), None)
            detail = load(os.path.join(data, "details", ticket_id + ".json"))
            if summary is None or detail is None:
                return self.reply(404, error("not_found", "No ticket with id %s" % ticket_id))
            detail["ticket"] = summary
            self.reply(200, detail)

        def cdn(self, path):
            name = os.path.basename(path)
            file = os.path.join(data, "cdn", name)
            if not name or not os.path.isfile(file):
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            with open(file, "rb") as handle:
                payload = handle.read()
            kind = {"png": "image/png", "jpg": "image/jpeg", "txt": "text/plain"}.get(name.rsplit(".", 1)[-1], "")
            self.send_response(200)
            self.send_header("Content-Type", kind or "application/octet-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    ThreadingHTTPServer.allow_reuse_address = True
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    if args.port_file:
        with open(args.port_file + ".tmp", "w") as handle:
            handle.write(str(server.server_address[1]))
        os.replace(args.port_file + ".tmp", args.port_file)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    time.sleep(args.lifetime)
    server.shutdown()


# Seeding


def seed(args):
    fixtures, out = args.fixtures, args.out
    os.makedirs(os.path.join(out, "details"), exist_ok=True)
    shutil.copy(os.path.join(fixtures, "me.json"), os.path.join(out, "me.json"))
    tickets = []
    for status in STATUSES:
        for ticket in load(os.path.join(fixtures, "tickets-%s.json" % status))["tickets"]:
            if all(t["id"] != ticket["id"] for t in tickets):
                tickets.append(ticket)
    fixture = load(os.path.join(fixtures, "ticket-detail.json"))
    for ticket in tickets:
        if ticket["id"] == fixture["ticket"]["id"]:
            detail = fixture
        else:
            detail = {
                "ticket": ticket, "messages": [], "problems": [], "draft": None, "notes": [],
                "handover": "# Handover: %s\n\nNo conversation yet.\n" % ticket["name"],
            }
        save(os.path.join(out, "details", ticket["id"] + ".json"), detail)
    if args.ui:
        tickets += ui_tickets(out)
    save(os.path.join(out, "tickets.json"), {"tickets": tickets})


def picture(source, out, width):
    """A PNG of one of this Mac's own pictures, for attachments and avatars. Missing pictures are left out."""
    if not os.path.exists(source):
        return
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(
        ["sips", "-s", "format", "png", "--resampleWidth", str(width), source, "--out", out],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def ui_tickets(out):
    now = int(time.time() * 1000)
    minute = 60 * 1000
    cdn = os.path.join(out, "cdn")
    picture("/System/Library/Desktop Pictures/Sonoma.heic", os.path.join(cdn, "checkout-error.png"), 1400)
    picture("/System/Library/Desktop Pictures/iMac Blue.heic", os.path.join(cdn, "screenshot.png"), 900)
    picture("/Library/User Pictures/Animals/Parrot.heic", os.path.join(cdn, "maya.png"), 128)
    picture("/Library/User Pictures/Animals/Owl.heic", os.path.join(cdn, "abc123.png"), 128)
    with open(os.path.join(cdn, "console-log.txt"), "w") as handle:
        handle.write("TypeError: Cannot read properties of undefined (reading 'total')\n")
    expired = "%x" % int(time.time() - 86400)
    channel = "1300000000000000855"
    maya = {"username": "mayaperez", "displayName": "Maya Perez", "avatarUrl": CDN + "avatars/301/maya.png?size=64",
            "role": "customer", "isBot": False}
    hindie = {"username": "hindiee21", "displayName": "Hindie", "avatarUrl": None, "role": "staff", "isBot": False}
    anish = {"username": "shwarmadev", "displayName": "Anish", "avatarUrl": None, "role": "staff", "isBot": False}
    bot = {"username": "Ticket Tool", "displayName": None, "avatarUrl": None, "role": "customer", "isBot": True}

    def message(number, author, minutes_ago, text, attachments=(), mentions=(), thread=None):
        return {
            "id": "15000000000000001%02d" % number, "author": author, "text": text,
            "discordUrl": "https://discord.com/channels/1100000000000000000/%s/15000000000000001%02d" % (
                thread["id"] if thread else channel, number),
            "attachments": list(attachments), "mentions": list(mentions), "postedAt": now - minutes_ago * minute,
            "thread": thread,
        }

    def attachment(name, size, kind, query=""):
        return {"filename": name, "size": size, "contentType": kind,
                "url": CDN + "attachments/%s/1500000000000000199/%s%s" % (channel, name, query)}

    maya_mention = {"id": "301", "username": "mayaperez", "displayName": "Maya Perez"}
    hindie_mention = {"id": "201", "username": "hindiee21", "displayName": "Hindie"}
    unnamed = {"id": "1400000000000000011", "name": None}
    named = {"id": "1400000000000000012", "name": "Checkout logs"}
    long_ticket = {
        "id": "0000000000000000000010011tickets", "name": "ticket-0855-mayaperez", "number": "0855",
        "customer": "mayaperez", "status": "open", "openedAt": now - 200 * minute, "lastActivityAt": now - 25 * minute,
        "owner": None, "waiting": True, "staleHours": None,
        "discordUrl": "https://discord.com/channels/1100000000000000000/" + channel,
    }
    messages = [
        message(1, bot, 200, "Welcome <@301>! Support will be with you shortly. Please describe the problem, and "
                "attach screenshots if you can.", mentions=[maya_mention]),
        message(2, maya, 199, "Hi! Checkout has been failing for **every** customer since this morning. They get to "
                "the payment step, press *Pay now*, and the page just __spins forever__ before showing an error. "
                "We changed nothing on our side, and ~~it worked yesterday~~ it was fine until about 9am."),
        message(3, maya, 198, "Here is what they see:", attachments=[
            attachment("checkout-error.png", 812345, "image/png"),
            attachment("screen-recording.gif", 62914560, "image/gif")]),
        message(4, maya, 196, "And the receipt from the last order that went through:",
                attachments=[attachment("receipt.png", 104857, "image/png",
                                        "?ex=%s&is=%s&hm=4f1c0a" % (expired, expired))]),
        message(5, hindie, 150, "Thanks <@301>, looking into it now. Could you run this in the browser console on "
                "the payment page and paste what it prints?\n```js\nconsole.log(window.checkout?.state)\n"
                "console.log(document.querySelector('#pay').dataset)\n```", mentions=[maya_mention]),
        message(6, maya, 120, "Sure, the log is attached. The `total` looks wrong to me.",
                attachments=[attachment("console-log.txt", 2150, "text/plain")]),
        message(7, maya, 118, "It prints `{ step: 'pay', total: undefined }` every time :pensive:"),
        message(8, anish, 90, "Moving the details into a thread so this channel stays readable.", thread=unnamed),
        message(9, anish, 89, "Found it in <#%s>: the cart total comes back **undefined** when a discount code is "
                "applied twice. See [the discount docs](https://docs.example.com/discounts) and "
                "https://status.example.com/incidents/42." % channel, thread=named),
        message(10, hindie, 60, "> the cart total comes back undefined\nConfirmed. A fix is on its way, "
                "<@201> will follow up. <:pepe_ok:1234567890>", mentions=[hindie_mention]),
        message(11, maya, 25, "Thank you both! Is there anything we can do in the meantime? Customers are "
                "emailing us about it and we would like to tell them something useful, even if it is just that "
                "removing the discount code works for now."),
    ]
    detail = {
        "ticket": long_ticket, "messages": messages,
        "problems": [
            {"key": "p1", "title": "Checkout spins forever at the payment step", "category": "bug", "status": "open",
             "bullets": ["Every customer since about 9am", "The page shows an error after spinning",
                         "The cart total is undefined when a discount code is applied twice"]},
            {"key": "p2", "title": "A workaround to tell customers", "category": "how-to", "status": "open",
             "bullets": ["Removing the discount code seems to work"]},
            {"key": "p3", "title": "Where to find the console", "category": "how-to", "status": "resolved",
             "bullets": ["Explained opening the browser's developer tools"]},
        ],
        "draft": {"text": "Hi Maya, thanks for the log. The cart total goes missing when a discount code is applied "
                          "twice, and a fix is on its way today. Until then, customers can check out by removing the "
                          "discount code and adding it once more. We will let you know as soon as the fix is live.",
                  "status": "ok", "sourcesUsed": ["conversation", "solisDb"], "generatedAt": now - 20 * minute,
                  "error": None},
        "handover": "# Handover: ticket-0855-mayaperez\n\nCheckout spins forever when a discount code is applied "
                    "twice.\n",
        "notes": [
            {"text": "Discount code applied twice leaves the cart total undefined.",
             "authorEmail": "anish@example.com", "createdAt": now - 85 * minute},
            {"text": "Fix in review. Tell the customer the workaround.", "authorEmail": "hindie@example.com",
             "createdAt": now - 40 * minute},
        ],
    }
    save(os.path.join(out, "details", long_ticket["id"] + ".json"), detail)

    closed_ticket = {
        "id": "0000000000000000000010012tickets", "name": "closed-0851-northwind", "number": "0851",
        "customer": "northwind", "status": "closed", "openedAt": now - 3000 * minute,
        "lastActivityAt": now - 1500 * minute,
        "owner": {"email": "anish@example.com", "initials": "AN", "via": "reply", "at": now - 1600 * minute},
        "waiting": False, "staleHours": None,
        "discordUrl": "https://discord.com/channels/1100000000000000000/1300000000000000851",
    }
    closed_channel = "1300000000000000851"
    northwind = {"username": "northwind", "displayName": "Northwind", "avatarUrl": None, "role": "customer",
                 "isBot": False}
    closed_messages = [
        {"id": "1500000000000000201", "author": northwind, "text": "Exports stop at 10,000 rows.",
         "discordUrl": "https://discord.com/channels/1100000000000000000/%s/1500000000000000201" % closed_channel,
         "attachments": [], "mentions": [], "postedAt": now - 1700 * minute, "thread": None},
        {"id": "1500000000000000202", "author": anish, "text": "Fixed in today's release, exports are unlimited now.",
         "discordUrl": "https://discord.com/channels/1100000000000000000/%s/1500000000000000202" % closed_channel,
         "attachments": [], "mentions": [], "postedAt": now - 1600 * minute, "thread": None},
        {"id": "1500000000000000203", "author": northwind, "text": "Works, thanks!",
         "discordUrl": "https://discord.com/channels/1100000000000000000/%s/1500000000000000203" % closed_channel,
         "attachments": [], "mentions": [], "postedAt": now - 1500 * minute, "thread": None},
    ]
    save(os.path.join(out, "details", closed_ticket["id"] + ".json"), {
        "ticket": closed_ticket, "messages": closed_messages,
        "problems": [{"key": "p1", "title": "Exports stop at 10,000 rows", "category": "bug", "status": "resolved",
                      "bullets": ["Fixed in the release"]}],
        "draft": None, "notes": [],
        "handover": "# Handover: closed-0851-northwind\n\nResolved.\n",
    })
    return [long_ticket, closed_ticket]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    seeding = commands.add_parser("seed")
    seeding.add_argument("--fixtures", required=True)
    seeding.add_argument("--out", required=True)
    seeding.add_argument("--ui", action="store_true")
    serving = commands.add_parser("serve")
    serving.add_argument("--data", required=True)
    serving.add_argument("--token", required=True)
    serving.add_argument("--not-staff-token")
    serving.add_argument("--port", type=int, default=0)
    serving.add_argument("--port-file")
    serving.add_argument("--log")
    serving.add_argument("--lifetime", type=float, default=1800)
    args = parser.parse_args()
    if args.command == "seed":
        seed(args)
    else:
        serve(args)


if __name__ == "__main__":
    sys.exit(main())
