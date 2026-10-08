import Foundation

/// The files Canopy keeps under ~/.canopy on a host, and the command that writes them.
public enum HostFiles {
    /// Changes whenever either file does, so a host with older files gets them again.
    public static let version = "\(CanopyVersion.current)+\(HomeID.hash(script + tmuxConf))"

    /// The remote command that writes the files, each through a temporary file and a rename, then the version, and
    /// has a tmux server already running read the new config. Contents travel in the command, base64-encoded.
    public static func installCommand(server: String) -> [String] {
        let program = """
            import base64, os, subprocess, sys
            home = os.path.expanduser("~/.canopy")
            def put(path, text, mode):
                path = os.path.join(home, path)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                temporary = path + ".canopy-new"
                with open(temporary, "wb") as file:
                    file.write(base64.b64decode(text))
                os.chmod(temporary, mode)
                os.replace(temporary, path)
            put("bin/canopy-host", sys.argv[1], 0o755)
            put("tmux.conf", sys.argv[2], 0o644)
            put("files-version", sys.argv[3], 0o644)
            subprocess.run(["tmux", "-u", "-L", sys.argv[4], "source-file", os.path.join(home, "tmux.conf")],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            """
        return [
            "python3", "-c", program, Data(script.utf8).base64EncodedString(),
            Data(tmuxConf.utf8).base64EncodedString(), Data(version.utf8).base64EncodedString(), server,
        ]
    }

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

    /// Canopy's helper on a host. `probe` lists the sessions of Canopy's tmux server, each with its foreground program,
    /// whether that is the shell, its folder, and its title, as JSON.
    public static let script = #"""
        #!/usr/bin/env python3
        """Canopy's helper on this host. Canopy installs and updates it; changes here are replaced."""
        import json
        import os
        import socket
        import subprocess
        import sys


        def processes():
            """Each process's terminal foreground group and name, by pid."""
            listed = subprocess.run(
                ["ps", "-A", "-o", "pid=,tpgid=,comm="], capture_output=True, encoding="utf-8", errors="replace"
            ).stdout
            table = {}
            for line in listed.splitlines():
                parts = line.split(None, 2)
                if len(parts) == 3 and parts[0].isdigit():
                    table[int(parts[0])] = (int(parts[1]) if parts[1].lstrip("-").isdigit() else 0,
                                            os.path.basename(parts[2].strip()))
            return table


        def probe(server):
            fields = "#{session_name}\t#{pane_pid}\t#{pane_current_path}\t#{pane_title}"
            # -u: under a locale that is not UTF-8, as ssh can pass on, tmux would print tabs as underscores.
            listed = subprocess.run(
                ["tmux", "-u", "-L", server, "list-panes", "-a", "-F", fields],
                capture_output=True, encoding="utf-8", errors="replace",
            )
            sessions = []
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


        def main(arguments):
            if len(arguments) == 3 and arguments[0] == "probe" and arguments[1] == "--server":
                probe(arguments[2])
                return 0
            print("usage: canopy-host probe --server <name>", file=sys.stderr)
            return 2


        if __name__ == "__main__":
            sys.exit(main(sys.argv[1:]))

        """#
}
