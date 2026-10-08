import Foundation

/// The files Canopy keeps on a host, and the command that writes them.
/// Each Canopy home keeps its own under `~/.canopy/<home id>`, so the release app and a dev build connected to one
/// host at once never replace each other's.
public enum HostFiles {
    /// Changes whenever any of the files does, so a host with older files gets them again.
    /// The shared `canopy` stays out of it: it is the same for every version and must never ask for an install.
    public static let version =
        "\(CanopyVersion.current)+\(HomeID.hash(scriptBody + canopyLauncherSource + xdgOpenLauncherSource + tmuxConf))"

    /// The remote command that writes this home's files, each through a temporary file and a rename, then the version,
    /// and has this home's tmux server, when it runs, read the new config. Contents travel in the command,
    /// base64-encoded. `~/.local/bin/canopy` links to the shared `canopy` so login shells find it, unless something
    /// else already has that name.
    /// Builds before each home had its own folder kept theirs in `~/.canopy/bin`, `~/.canopy/tmux.conf`, and
    /// `~/.canopy/files-version`. Those stay, since an older build on another home may still use them.
    public static func installCommand(homeID: String) -> [String] {
        let program = """
            import base64, os, subprocess, sys
            canopy = os.path.expanduser("~/.canopy")
            home = os.path.join(canopy, sys.argv[1])
            def put(path, text, mode):
                os.makedirs(os.path.dirname(path), exist_ok=True)
                temporary = path + ".canopy-new-" + str(os.getpid())
                with open(temporary, "wb") as file:
                    file.write(text)
                os.chmod(temporary, mode)
                os.replace(temporary, path)
            def own(path, text, mode):
                put(os.path.join(home, path), base64.b64decode(text), mode)
            own("bin/canopy-host", sys.argv[3], 0o755)
            own("bin/canopy", sys.argv[4], 0o755)
            own("bin/xdg-open", sys.argv[5], 0o755)
            own("tmux.conf", sys.argv[6], 0o644)
            shared = os.path.join(canopy, "bin/canopy")
            content = base64.b64decode(sys.argv[7])
            try:
                with open(shared, "rb") as file:
                    current = file.read()
            except OSError:
                current = None
            if current != content or not os.access(shared, os.X_OK):
                put(shared, content, 0o755)
            link = os.path.expanduser("~/.local/bin/canopy")
            try:
                if not os.path.lexists(link):
                    os.makedirs(os.path.dirname(link), exist_ok=True)
                    os.symlink(shared, link)
            except OSError:
                pass  # Panes find this home's canopy on their own PATH anyway.
            own("files-version", sys.argv[8], 0o644)
            try:
                subprocess.run(["tmux", "-u", "-L", sys.argv[2], "source-file", os.path.join(home, "tmux.conf")],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                pass  # Without tmux there is no server to tell.
            """
        let files = [
            script, canopyLauncher(homeID: homeID), xdgOpenLauncher(homeID: homeID), tmuxConf, sharedCanopy, version,
        ].map { Data($0.utf8).base64EncodedString() }
        return ["python3", "-c", program, homeID, HostPaths.tmuxServer(homeID: homeID)] + files
    }

    /// `~/.canopy/<home id>/bin/canopy`, which this home's panes on the host find first on their PATH.
    public static func canopyLauncher(homeID: String) -> String {
        canopyLauncherSource.replacingOccurrences(of: "@CANOPY_HOME_ID@", with: homeID)
    }

    /// `~/.canopy/<home id>/bin/xdg-open`, which programs in this home's panes on the host open links with.
    public static func xdgOpenLauncher(homeID: String) -> String {
        xdgOpenLauncherSource.replacingOccurrences(of: "@CANOPY_HOME_ID@", with: homeID)
    }

    private static let canopyLauncherSource =
        "#!/bin/sh\nexec python3 \"$HOME/.canopy/@CANOPY_HOME_ID@/bin/canopy-host\" relay \"$@\"\n"

    private static let xdgOpenLauncherSource =
        "#!/bin/sh\nexec python3 \"$HOME/.canopy/@CANOPY_HOME_ID@/bin/canopy-host\" open \"$@\"\n"

    /// `~/.canopy/bin/canopy`, the same for every home and every build, which `~/.local/bin/canopy` links to.
    /// A pane whose shell's startup files put other folders before its home's own still reaches its home's `canopy`.
    /// A remote pane's session from before the CLI reached hosts has CANOPY_HOST and CANOPY_PANE but no
    /// CANOPY_HOME_ID, and inside tmux TERM_PROGRAM is tmux's, so those name such a terminal.
    public static let sharedCanopy = """
        #!/bin/sh
        # Written by Canopy. Runs the canopy of the Canopy terminal it is in.
        if [ -n "$CANOPY_HOME_ID" ] && [ -x "$HOME/.canopy/$CANOPY_HOME_ID/bin/canopy" ]; then
            exec "$HOME/.canopy/$CANOPY_HOME_ID/bin/canopy" "$@"
        fi
        if [ -z "$CANOPY_HOME_ID" ] && [ -n "$CANOPY_HOST" ] && [ -n "$CANOPY_PANE" ]; then
            echo "This terminal started before Canopy's CLI reached this host. A new Canopy terminal has it." >&2
            exit 1
        fi
        echo "Run canopy in a Canopy terminal on this host." >&2
        exit 1

        """

    /// Reads this home's installed version, or prints nothing when there is none.
    public static func versionCommand(homeID: String) -> [String] {
        ["sh", "-c", #"cat "$HOME/.canopy/$0/files-version" 2>/dev/null; true"#, homeID]
    }

    /// Prints the pane's hook report the host kept while the app was away, removing it, or prints nothing.
    public static func replayCommand(homeID: String, pane: String) -> [String] {
        [
            "sh", "-c", #"exec python3 "$HOME/.canopy/$0/bin/canopy-host" replay --pane "$1" --home-id "$0""#, homeID,
            pane,
        ]
    }

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
    /// its folder, and its title, and the panes with a kept hook report, as JSON. `relay` is the host's `canopy`, `replay` hands the app a hook's report that
    /// found no app, and `open` is the host's `xdg-open`.
    public static let script = scriptBody.replacingOccurrences(of: "@CANOPY_VERSION@", with: version)

    private static let scriptBody = scriptSource.replacingOccurrences(of: "@INPUT_COMMANDS@", with: RelayInput.literal)

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
        # The CLI's commands that read standard input on the Mac, from `RelayInput.commands`, and how this relay reads it
        # for them. Every other command gets none, so it never takes input meant for what runs after it.
        INPUT_COMMANDS = @INPUT_COMMANDS@
        # As `canopy ticket connect` reads a token on the Mac (`TokenInput`): its first line, within this wait and length.
        LINE_WAIT = 10
        LONGEST_LINE = 64 * 1024
        # The app acknowledges a request as soon as it reads it. sshd here accepts connections on the forwarded socket
        # even while the Mac sleeps, so silence for this long means the request never reached the app.
        ACKNOWLEDGEMENT_WAIT = 10
        # While a call runs the app sends a heartbeat every 15 seconds. A Mac that slept or changed network can leave
        # sshd here holding the connection for hours, so a call that hears nothing for this long gives up.
        REPLY_SILENCE = 45
        # Claude kills a hook 5 seconds after starting it, so a hook has its input by the first of these, from when it
        # started, has the app's acknowledgement or keeps its report by the second, and waits for the reply until the
        # third.
        HOOK_INPUT_WAIT = 1
        HOOK_BUDGET = 3
        HOOK_REPLY_WAIT = 4


        def command_input(arguments):
            """How the command in `arguments` reads standard input on the Mac, or None for one that reads none."""
            words = [argument for argument in arguments if not argument.startswith("-")]
            for command, kind in INPUT_COMMANDS:
                if words[:len(command)] == command:
                    return kind
            return None


        def piped_input():
            """Standard input's descriptor, unless it is a terminal or there is none."""
            try:
                if sys.stdin is None or sys.stdin.isatty() or not sys.stdin.readable():
                    return None
                return sys.stdin.fileno()
            except (OSError, ValueError):
                return None


        def hook_input(deadline):
            """What arrived on standard input by the deadline, base64, so a pipe that never closes cannot hold a hook
            past Claude's timeout."""
            descriptor = piped_input()
            if descriptor is None:
                return None
            try:
                if not select.select([descriptor], [], [], max(0.0, deadline - time.monotonic()))[0]:
                    return None
                data = bytearray()
                while True:
                    chunk = os.read(descriptor, 65536)
                    data += chunk
                    remaining = deadline - time.monotonic()
                    if not chunk or remaining <= 0 or not select.select([descriptor], [], [], remaining)[0]:
                        break
                return base64.b64encode(bytes(data)).decode("ascii")
            except (OSError, ValueError):
                return None


        def first_line():
            """Standard input's first line, base64, read a byte at a time so what follows stays for the next reader. Without
            a whole line or the end of input within LINE_WAIT, none, as the Mac's CLI would give up too."""
            descriptor = piped_input()
            if descriptor is None:
                return None
            deadline = time.monotonic() + LINE_WAIT
            data = bytearray()
            try:
                while len(data) <= LONGEST_LINE:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not select.select([descriptor], [], [], remaining)[0]:
                        return None
                    byte = os.read(descriptor, 1)
                    data += byte
                    if not byte or byte == b"\n":
                        break
            except (OSError, ValueError):
                return None
            return base64.b64encode(bytes(data)).decode("ascii")


        def folder():
            """The working folder as the shell names it: PWD when it names this folder, so a HOME reached through a link
            keeps the name remote rows' paths use, or else the real path."""
            shell = os.environ.get("PWD", "")
            try:
                if shell.startswith("/") and os.path.samefile(shell, "."):
                    return shell
            except OSError:
                pass
            try:
                return os.getcwd()
            except OSError:
                return shell or "/"


        class Lines:
            """A connection's JSON lines, one at a time, each by a deadline on this host's clock."""

            def __init__(self, connection):
                self.connection = connection
                self.data = bytearray()

            def next(self, deadline):
                while b"\n" not in self.data:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise socket.timeout("no line in time")
                    self.connection.settimeout(remaining)
                    chunk = self.connection.recv(65536)
                    if not chunk:
                        raise ConnectionError("the connection ended")
                    self.data += chunk
                line, _, rest = bytes(self.data).partition(b"\n")
                self.data = bytearray(rest)
                return json.loads(line)


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


        def left(deadline):
            """Seconds until a deadline on this host's clock, raising once it has passed."""
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise socket.timeout("out of time")
            return remaining


        def connect(path, timeout):
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(timeout)
            try:
                connection.connect(path)
            except BaseException:
                connection.close()
                raise
            return connection


        def send(connection, request, wait, deadline=None):
            """Sends the request and returns its lines and the app's first: its acknowledgement, or a reply without one,
            which means it ran nothing, as for a relay of another version. Raises when neither comes within `wait`
            seconds of the request going, or by `deadline`, or the connection ends first."""
            request["age"] = max(0.0, time.monotonic() - STARTED)
            data = memoryview(json.dumps(request).encode("ascii") + b"\n")
            # Each part must go within the wait, rather than all of it, so a long input on a slow link still goes.
            while data:
                connection.settimeout(wait if deadline is None else min(wait, left(deadline)))
                data = data[connection.send(data):]
            lines = Lines(connection)
            acknowledgement = time.monotonic() + wait
            return lines, lines.next(acknowledgement if deadline is None else min(acknowledgement, deadline))


        def acknowledged(line):
            return isinstance(line, dict) and line.get("ack") is True


        def reply_after(lines):
            """The reply after the acknowledgement, passing over the app's heartbeats, each of which must come within
            REPLY_SILENCE of the last line. A relayed command may run as long as it likes, such as `term wait`."""
            while True:
                line = lines.next(time.monotonic() + REPLY_SILENCE)
                if not (isinstance(line, dict) and line.get("alive") is True):
                    return line


        def decoded(reply):
            return (base64.b64decode(reply["stdout"], validate=True),
                    base64.b64decode(reply["stderr"], validate=True), int(reply["status"]))


        def relay(arguments):
            """The host's `canopy`: runs the app's CLI with these arguments and prints what it printed."""
            path = os.environ.get("CANOPY_SOCKET", "")
            reads = command_input(arguments)
            if reads == "hook":
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
            request = request_for(arguments, first_line() if reads == "line" else None)
            try:
                with connect(path, ACKNOWLEDGEMENT_WAIT) as connection:
                    lines, first = send(connection, request, ACKNOWLEDGEMENT_WAIT)
                    output, errors, status = decoded(reply_after(lines) if acknowledged(first) else first)
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                print(UNREACHABLE, file=sys.stderr)
                return 1
            write(sys.stdout, output)
            write(sys.stderr, errors)
            return status


        def hook(path, arguments):
            request = request_for(arguments, hook_input(STARTED + HOOK_INPUT_WAIT))
            deadline = STARTED + HOOK_BUDGET
            try:
                with connect(path, left(deadline)) as connection:
                    lines, first = send(connection, request, HOOK_BUDGET, deadline)
                    if acknowledged(first):
                        # The app has the report, so it is not kept. Were the acknowledgement lost on its way here,
                        # the report would be kept although the app ran it, and run again at replay: rare, and better
                        # than losing it.
                        try:
                            lines.next(STARTED + HOOK_REPLY_WAIT)
                        except (OSError, ValueError):
                            pass
                        return
            except (OSError, ValueError):
                pass
            keep(request)


        def request_for(arguments, stdin):
            return {
                "version": VERSION, "args": arguments, "cwd": folder(),
                "env": {key: value for key, value in os.environ.items() if key.startswith("CANOPY_")},
                "stdin": stdin,
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


        def is_canopys(folder, own):
            """Whether a folder is one of Canopy's on this host: this script's, the shared one, or another home's."""
            folder = os.path.realpath(folder)
            root = os.path.realpath(os.path.expanduser("~/.canopy"))
            return folder == own or (os.path.basename(folder) == "bin"
                                     and root in (os.path.dirname(folder), os.path.dirname(os.path.dirname(folder))))


        def next_opener():
            """The host's own xdg-open: the first on PATH that is not Canopy's, however it is reached."""
            own = os.path.dirname(os.path.realpath(__file__))
            for entry in os.environ.get("PATH", "").split(os.pathsep):
                if not entry or is_canopys(entry, own):
                    continue
                candidate = os.path.join(entry, "xdg-open")
                if not os.path.isfile(candidate) or not os.access(candidate, os.X_OK):
                    continue
                if is_canopys(os.path.dirname(os.path.realpath(candidate)), own):
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


        def pending_panes(home_id):
            """The panes with a report kept for this home, for the app to replay without waiting for them to attach."""
            folder = os.path.join(os.path.expanduser("~/.canopy"), home_id, "pending")
            try:
                names = os.listdir(folder)
            except OSError:
                return []
            return sorted(name[:-len(".json")] for name in names
                          if name.endswith(".json") and NAME.fullmatch(name[:-len(".json")]))


        def probe(server, home_id):
            pending = pending_panes(home_id)
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
                print(json.dumps({"sessions": sessions, "pending": pending}))
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
            print(json.dumps({"sessions": sessions, "pending": pending}))


        def usage():
            print("usage: canopy-host probe --server <name> --home-id <id> | relay <arguments> | replay --pane <pane> --home-id <id>"
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
            if (len(arguments) == 5 and command == ["probe"] and arguments[1] == "--server"
                    and arguments[3] == "--home-id" and NAME.fullmatch(arguments[4])):
                probe(arguments[2], arguments[4])
                return 0
            return usage()


        if __name__ == "__main__":
            try:
                sys.exit(main(sys.argv[1:]))
            except KeyboardInterrupt:
                sys.exit(130)

        """#
}
