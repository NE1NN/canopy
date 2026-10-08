import Foundation

/// The files Canopy keeps under ~/.canopy on a host, and the command that writes them.
public enum HostFiles {
    /// Changes whenever any of the files does, so a host with older files gets them again.
    public static let version =
        "\(CanopyVersion.current)+\(HomeID.hash(scriptSource + canopyLauncher + xdgOpenLauncher + tmuxConf))"

    /// The remote command that writes the files, each through a temporary file and a rename, then the version, and
    /// has a tmux server already running read the new config. Contents travel in the command, base64-encoded.
    /// `~/.local/bin/canopy` links to the relay so login shells find it, unless something else already has that name.
    public static func installCommand(server: String) -> [String] {
        let program = """
            import base64, os, subprocess, sys
            home = os.path.expanduser("~/.canopy")
            def put(path, text, mode):
                path = os.path.join(home, path)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                temporary = path + ".canopy-new-" + str(os.getpid())
                with open(temporary, "wb") as file:
                    file.write(base64.b64decode(text))
                os.chmod(temporary, mode)
                os.replace(temporary, path)
            put("bin/canopy-host", sys.argv[1], 0o755)
            put("bin/canopy", sys.argv[2], 0o755)
            put("bin/xdg-open", sys.argv[3], 0o755)
            put("tmux.conf", sys.argv[4], 0o644)
            relay = os.path.join(home, "bin/canopy")
            link = os.path.expanduser("~/.local/bin/canopy")
            try:
                if not os.path.lexists(link):
                    os.makedirs(os.path.dirname(link), exist_ok=True)
                    os.symlink(relay, link)
            except OSError:
                pass  # Panes find the relay on their own PATH anyway.
            put("files-version", sys.argv[5], 0o644)
            try:
                subprocess.run(["tmux", "-u", "-L", sys.argv[6], "source-file", os.path.join(home, "tmux.conf")],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                pass  # Without tmux there is no server to tell.
            """
        let files = [script, canopyLauncher, xdgOpenLauncher, tmuxConf, version].map {
            Data($0.utf8).base64EncodedString()
        }
        return ["python3", "-c", program] + files + [server]
    }

    /// `~/.canopy/bin/canopy`, which panes on the host find first on their PATH.
    public static let canopyLauncher = "#!/bin/sh\nexec python3 \"$HOME/.canopy/bin/canopy-host\" relay \"$@\"\n"

    /// `~/.canopy/bin/xdg-open`, which programs in panes on the host open links with.
    public static let xdgOpenLauncher = "#!/bin/sh\nexec python3 \"$HOME/.canopy/bin/canopy-host\" open \"$@\"\n"

    /// Reads the installed version, or prints nothing when there is none.
    public static let versionCommand = ["sh", "-c", "cat ~/.canopy/files-version 2>/dev/null; true"]

    /// tmux settings for Canopy's own server. Lines scrolled off a session's one window go into Canopy's scrollback,
    /// so scrolling and selecting work as in a local pane, and titles and copies reach Canopy.
    public static let tmuxConf = """
        # Written by Canopy. Changes here are replaced when Canopy updates it.
        set -g status off
        set -g mouse off
        set -sg escape-time 0
        set -g history-limit 50000
        set -g default-terminal "tmux-256color"
        set -ga terminal-overrides ",xterm-256color:Tc:smcup@:rmcup@"
        set -g set-titles on
        set -g set-titles-string "#{?#{||:#{==:#{pane_title},#{host}},#{==:#{pane_title},#{host_short}}},#{pane_current_command},#{pane_title}}"
        set -s set-clipboard on
        set -g allow-passthrough on
        set -g focus-events on
        set -g window-size latest
        set -g destroy-unattached off

        """

    /// Canopy's helper on a host, with the version it reports to the app.
    /// `probe` lists the sessions of Canopy's tmux server, each with its foreground program, whether that is the shell,
    /// its folder, and its title, as JSON. `relay` is the host's `canopy`, `replay` hands the app a hook's report that
    /// found no app, and `open` is the host's `xdg-open`.
    public static let script = scriptSource.replacingOccurrences(of: "@CANOPY_VERSION@", with: version)

    private static let scriptSource = #"""
        #!/usr/bin/env python3
        """Canopy's helper on this host. Canopy installs and updates it; changes here are replaced."""
        import base64
        import json
        import os
        import re
        import select
        import socket
        import subprocess
        import sys
        import time
        import urllib.parse

        STARTED = time.monotonic()
        VERSION = "@CANOPY_VERSION@"
        UNREACHABLE = "Canopy is not reachable from this host right now."
        NAME = re.compile(r"[A-Za-z0-9_-]+")
        # Long enough for a slow producer, such as a keychain, piping into `canopy ticket connect`; bounded, since a pipe
        # its parent never closes would otherwise hold every command forever.
        INPUT_WAIT = 10
        # A hook reports and goes: Claude waits on it, and a stalled connection must not hold Claude for long.
        HOOK_TIMEOUT = 10


        def standard_input():
            """Standard input, base64, unless it is a terminal or nothing arrives on it."""
            try:
                if sys.stdin is None or sys.stdin.isatty() or not sys.stdin.readable():
                    return None
                if not select.select([sys.stdin], [], [], INPUT_WAIT)[0]:
                    return None
                return base64.b64encode(sys.stdin.buffer.read()).decode("ascii")
            except (OSError, ValueError):
                return None


        def folder():
            try:
                return os.getcwd()
            except OSError:
                return os.environ.get("PWD") or "/"


        def receive_line(connection):
            data = bytearray()
            while b"\n" not in data:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                data += chunk
            return bytes(data).split(b"\n", 1)[0]


        def write(stream, data):
            try:
                stream.flush()
                stream.buffer.write(data)
                stream.buffer.flush()
            except (OSError, ValueError):
                pass  # A reader that went away, as `canopy ... | head` has.


        def keep(request):
            """Saves a hook's report the app could not take, replacing the pane's last, for the app to replay."""
            home_id = request["env"].get("CANOPY_HOME_ID", "")
            pane = request["env"].get("CANOPY_PANE", "")
            if not NAME.fullmatch(home_id) or not NAME.fullmatch(pane):
                return
            pending = os.path.join(os.path.expanduser("~/.canopy"), home_id, "pending")
            path = os.path.join(pending, pane + ".json")
            # Dated by this host's clock both when kept and when replayed, so the report keeps its hook's time.
            request["age"] = max(0.0, time.monotonic() - STARTED)
            request["kept"] = time.time()
            temporary = path + ".canopy-new-" + str(os.getpid())
            try:
                os.makedirs(pending, mode=0o700, exist_ok=True)
                descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(descriptor, "w") as file:
                    os.fchmod(file.fileno(), 0o600)
                    file.write(json.dumps(request))
                os.replace(temporary, path)
            except OSError:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass


        def connect(path, timeout):
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(timeout)
            try:
                connection.connect(path)
            except BaseException:
                connection.close()
                raise
            return connection


        def exchange(connection, request):
            """Sends the request and returns the app's reply, or raises when there is none."""
            with connection:
                request["age"] = max(0.0, time.monotonic() - STARTED)
                connection.sendall(json.dumps(request).encode("ascii") + b"\n")
                reply = json.loads(receive_line(connection))
                return (base64.b64decode(reply["stdout"], validate=True),
                        base64.b64decode(reply["stderr"], validate=True), int(reply["status"]))


        def relay(arguments):
            """The host's `canopy`: runs the app's CLI with these arguments and prints what it printed."""
            path = os.environ.get("CANOPY_SOCKET", "")
            if arguments[:1] == ["agent-hook"]:
                # A hook never prints and never fails, so it can never disturb Claude.
                try:
                    if path:
                        hook(path, arguments)
                except Exception:
                    pass
                return 0
            if not path:
                print("Run canopy in a Canopy terminal on this host.", file=sys.stderr)
                return 1
            try:
                output, errors, status = exchange(connect(path, None), request_for(arguments))
            except (OSError, ValueError, KeyError, TypeError):
                print(UNREACHABLE, file=sys.stderr)
                return 1
            write(sys.stdout, output)
            write(sys.stderr, errors)
            return status


        def hook(path, arguments):
            request = request_for(arguments)
            try:
                connection = connect(path, HOOK_TIMEOUT)
            except OSError:
                keep(request)
                return
            # Once connected, the app may have run it, so it is not kept: the app must never run one report twice.
            exchange(connection, request)


        def request_for(arguments):
            return {
                "version": VERSION, "args": arguments, "cwd": folder(),
                "env": {key: value for key, value in os.environ.items() if key.startswith("CANOPY_")},
                "stdin": standard_input(),
            }


        def replay(pane, home_id):
            """Prints the pane's kept hook report and removes it, so the app runs it once."""
            if not NAME.fullmatch(pane) or not NAME.fullmatch(home_id):
                return usage()
            path = os.path.join(os.path.expanduser("~/.canopy"), home_id, "pending", pane + ".json")
            # Moved aside first, so a report a hook keeps meanwhile waits for the next replay instead of being removed.
            taken = path + ".canopy-replay-" + str(os.getpid())
            try:
                os.rename(path, taken)
            except FileNotFoundError:
                return 0
            try:
                with open(taken, encoding="utf-8") as file:
                    report = file.read().strip()
            finally:
                os.unlink(taken)
            if not report:
                return 0
            try:
                request = json.loads(report)
                request["age"] = float(request.get("age") or 0) + max(0.0, time.time() - float(request.pop("kept")))
                report = json.dumps(request)
            except (ValueError, KeyError, TypeError, AttributeError):
                pass
            print(report)
            return 0


        ARTIFACT_ID = re.compile(r"[A-Za-z0-9_-]+")
        UUID = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")


        def is_artifact(text):
            """The app's rule for a claude.ai artifact's link, which opens in Canopy: `ArtifactLink` in WebLinks.swift."""
            try:
                parts = urllib.parse.urlsplit(text.strip())
                port = parts.port
            except ValueError:
                return False
            if (parts.scheme.lower() != "https" or parts.username is not None or parts.password is not None
                    or port is not None or (parts.hostname or "") not in ("claude.ai", "www.claude.ai")):
                return False
            path = parts.path[:-1] if parts.path.endswith("/") else parts.path
            segments = path.split("/")
            if len(segments) == 3 and segments[1] == "artifact":
                return ARTIFACT_ID.fullmatch(segments[2]) is not None
            if len(segments) == 4 and segments[1] == "code" and segments[2] == "artifact":
                return UUID.fullmatch(segments[3]) is not None
            return False


        def next_opener():
            """The host's own xdg-open: the first on PATH that is not Canopy's, however it is reached."""
            canopy = os.path.realpath(os.path.expanduser("~/.canopy/bin"))
            own = os.path.join(canopy, "xdg-open")
            for entry in os.environ.get("PATH", "").split(os.pathsep):
                if not entry or os.path.realpath(entry) == canopy:
                    continue
                candidate = os.path.join(entry, "xdg-open")
                if not os.path.isfile(candidate) or not os.access(candidate, os.X_OK):
                    continue
                try:
                    if os.path.exists(own) and os.path.samefile(candidate, own):
                        continue
                except OSError:
                    continue
                return candidate
            return None


        def open_link(arguments):
            """The host's `xdg-open`: an artifact opens in its row in Canopy, anything else as it would without Canopy."""
            if len(arguments) == 1 and is_artifact(arguments[0]) and os.environ.get("CANOPY_SOCKET"):
                return relay(["web", "open", arguments[0]])
            opener = next_opener()
            if opener is not None:
                try:
                    os.execv(opener, [opener] + arguments)
                except OSError:
                    pass
            print("xdg-open: no handler for " + " ".join(arguments), file=sys.stderr)
            return 3


        def processes():
            """Each process's terminal foreground group and name, by pid, without a login shell's leading dash."""
            listed = subprocess.run(
                ["ps", "-A", "-o", "pid=,tpgid=,comm="], capture_output=True, encoding="utf-8", errors="replace"
            ).stdout
            table = {}
            for line in listed.splitlines():
                parts = line.split(None, 2)
                if len(parts) == 3 and parts[0].isdigit():
                    table[int(parts[0])] = (int(parts[1]) if parts[1].lstrip("-").isdigit() else 0,
                                            os.path.basename(parts[2].strip()).lstrip("-"))
            return table


        def probe(server):
            fields = "#{session_name}\t#{pane_pid}\t#{pane_current_path}\t#{pane_title}"
            # -u: under a locale that is not UTF-8, as ssh can pass on, tmux would print tabs as underscores.
            sessions = []
            try:
                listed = subprocess.run(
                    ["tmux", "-u", "-L", server, "list-panes", "-a", "-F", fields],
                    capture_output=True, encoding="utf-8", errors="replace",
                )
            except OSError:
                # Without tmux there are no sessions, as when its server is not running.
                print(json.dumps({"sessions": sessions}))
                return
            # tmux titles a pane nothing has titled with the machine's name, which says nothing.
            names = {socket.gethostname(), socket.gethostname().split(".")[0]}
            if listed.returncode == 0:
                table = processes()
                for line in listed.stdout.splitlines():
                    parts = line.split("\t")
                    if len(parts) < 4 or not parts[1].isdigit():
                        continue
                    pid = int(parts[1])
                    group, shell = table.get(pid, (pid, ""))
                    busy = group > 0 and group != pid
                    foreground = table.get(group, (0, shell))[1] if busy else shell
                    title = "\t".join(parts[3:])
                    sessions.append({
                        "name": parts[0], "pid": pid, "busy": busy, "foreground": foreground,
                        "folder": parts[2], "title": "" if title in names else title,
                    })
            print(json.dumps({"sessions": sessions}))


        def usage():
            print("usage: canopy-host probe --server <name> | relay <arguments> | replay --pane <pane> --home-id <id>"
                  " | open <url>", file=sys.stderr)
            return 2


        def main(arguments):
            command = arguments[:1]
            if command == ["relay"]:
                return relay(arguments[1:])
            if command == ["open"]:
                return open_link(arguments[1:])
            if len(arguments) == 5 and command == ["replay"] and arguments[1] == "--pane" and arguments[3] == "--home-id":
                return replay(arguments[2], arguments[4])
            if len(arguments) == 3 and command == ["probe"] and arguments[1] == "--server":
                probe(arguments[2])
                return 0
            return usage()


        if __name__ == "__main__":
            try:
                sys.exit(main(sys.argv[1:]))
            except KeyboardInterrupt:
                sys.exit(130)

        """#
}
