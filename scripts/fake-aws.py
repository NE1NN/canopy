#!/usr/bin/env python3
"""AWS for tests, on loopback: the EC2 instance metadata service (IMDSv2) that canopy-box asks which instance it is,
and EC2's StartInstances that the phone signs to wake a box.

  fake-aws.py --port-file <file> [--instance i-...] [--region ...] [--key-id <id>] [--on-start <command>]
              [--log <file>] [--lifetime <seconds>]

StartInstances checks that the request is signed with Signature Version 4 for --key-id, answers that the instance is
pending, and runs --on-start after --boot seconds, as an instance takes a while to boot.
"""
import argparse
import json
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "fake-imds-token"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--instance", default="i-0fake0box00000001")
    parser.add_argument("--region", default="ap-southeast-2")
    parser.add_argument("--key-id", default="AKIAFAKEWAKEKEY")
    parser.add_argument("--on-start")
    parser.add_argument("--boot", type=float, default=5)
    parser.add_argument("--log")
    parser.add_argument("--lifetime", type=float, default=4 * 3600)
    options = parser.parse_args()
    lock = threading.Lock()

    def log(entry):
        if options.log:
            with lock, open(options.log, "a") as file:
                file.write(json.dumps(entry) + "\n")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body, content_type="text/plain"):
            data = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_PUT(self):
            if self.path == "/latest/api/token":
                self.reply(200, TOKEN)
            else:
                self.reply(404, "")

        def do_GET(self):
            if self.headers.get("X-aws-ec2-metadata-token") != TOKEN:
                return self.reply(401, "")
            values = {"/latest/meta-data/instance-id": options.instance,
                      "/latest/meta-data/placement/region": options.region}
            self.reply(200, values[self.path]) if self.path in values else self.reply(404, "")

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
            authorization = self.headers.get("Authorization", "")
            signed = authorization.startswith(f"AWS4-HMAC-SHA256 Credential={options.key_id}/")
            log({"body": body, "signed": signed})
            if not signed:
                return self.reply(401, error("AuthFailure", "AWS was not able to validate the provided access credentials"))
            if "Action=StartInstances" not in body or f"InstanceId.1={options.instance}" not in body:
                return self.reply(400, error("InvalidInstanceID.NotFound", "No such instance."))
            if options.on_start:
                threading.Timer(options.boot, lambda: subprocess.Popen(
                    options.on_start, shell=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, start_new_session=True)).start()
            self.reply(200, "<StartInstancesResponse><instancesSet><item><currentState><code>0</code><name>pending"
                            "</name></currentState></item></instancesSet></StartInstancesResponse>", "text/xml")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(options.port_file, "w") as file:
        file.write(str(server.server_address[1]))
    threading.Timer(options.lifetime, server.shutdown).start()
    server.serve_forever()


def error(code, message):
    return f"<Response><Errors><Error><Code>{code}</Code><Message>{message}</Message></Error></Errors></Response>"


if __name__ == "__main__":
    main()
