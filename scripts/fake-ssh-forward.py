"""Plays one of an ssh master's local forwards for scripts/fake-ssh: listens on 127.0.0.1 and ::1 at a port, as ssh
does, and joins each connection to the target. It writes its ready file once it listens, exits 255 when it can bind
neither address, and exits once the master it belongs to has.

Usage: python3 fake-ssh-forward.py <control path> <master pid> <local port> <target> <target port> <ready file>"""
import os
import select
import socket
import sys
import threading


def listeners(port):
    """Sockets on both loopbacks, as ssh binds them, with SO_REUSEADDR as ssh sets it. Either alone is enough."""
    bound = []
    for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            listener = socket.socket(family, socket.SOCK_STREAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind((address, port))
            listener.listen(128)
            bound.append(listener)
        except OSError:
            pass
    return bound


def master_runs(control, master):
    try:
        os.kill(master, 0)
        with open(control, encoding="ascii") as file:
            return file.read().strip() == str(master)
    except (OSError, ValueError):
        return False


def pump(source, sink):
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            sink.sendall(data)
    except OSError:
        pass
    finally:
        for end in (source, sink):
            try:
                end.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def join(client, target, port):
    try:
        upstream = socket.create_connection((target, port), timeout=10)
        upstream.settimeout(None)
    except OSError:
        client.close()
        return
    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


def main(arguments):
    control, master, local, target, port, ready = arguments
    # Out of fake-ssh's session, whose group a timed-out call is killed with, as a forward lives in the master.
    os.setsid()
    bound = listeners(int(local))
    if not bound:
        return 255
    with open(ready + ".tmp", "w", encoding="ascii") as file:
        file.write("ok\n")
    os.replace(ready + ".tmp", ready)
    target = target.strip("[]")
    while master_runs(control, int(master)):
        readable, _, _ = select.select(bound, [], [], 0.5)
        for listener in readable:
            try:
                client, _ = listener.accept()
            except OSError:
                continue
            join(client, target, int(port))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
