#!/usr/bin/env python3
"""Records a real session's bytes for tests/replay.bend (a dev tool only;
Blink itself needs no Python). Connects with trust auth, runs QUERIES with
the simple query protocol, and writes what each side sent:

  session.server.bin  every byte the server sent
  session.client.bin  every byte after the startup message the client sent

  PGUSER=trusty PGDATABASE=world python3 tests/fixtures/capture.py
"""
import os
import socket
import struct

QUERIES = [
    "SELECT 1::int4 AS one, 'héllo'::text AS t, NULL::text AS n, true AS b, -42 AS neg; SELECT 1/0",
    "SELECT 'after' AS a",
]


def message(tag, body):
    return tag + struct.pack("!I", len(body) + 4) + body


def until_ready(sock, server):
    """Reads whole messages until ReadyForQuery."""
    buf = b""
    while True:
        while len(buf) >= 5:
            size = struct.unpack("!I", buf[1:5])[0] + 1
            if len(buf) < size:
                break
            tag, buf = buf[:1], buf[size:]
            if tag == b"Z":
                return
        chunk = sock.recv(65536)
        if not chunk:
            raise SystemExit("server closed the connection")
        server.extend(chunk)
        buf += chunk


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    user = os.environ.get("PGUSER", os.environ.get("USER", "postgres"))
    db = os.environ.get("PGDATABASE", user)
    sock = socket.create_connection((os.environ.get("PGHOST", "127.0.0.1"),
                                     int(os.environ.get("PGPORT", "5432"))))
    params = b"".join(s.encode() + b"\0" for s in
                      ["user", user, "database", db, "client_encoding", "UTF8"]) + b"\0"
    startup = struct.pack("!II", len(params) + 8, 196608) + params
    server, client = bytearray(), bytearray()
    sock.sendall(startup)
    until_ready(sock, server)
    for q in QUERIES:
        m = message(b"Q", q.encode() + b"\0")
        client.extend(m)
        sock.sendall(m)
        until_ready(sock, server)
    bye = message(b"X", b"")
    client.extend(bye)
    sock.sendall(bye)
    sock.close()
    with open(os.path.join(here, "session.server.bin"), "wb") as f:
        f.write(server)
    with open(os.path.join(here, "session.client.bin"), "wb") as f:
        f.write(client)
    print(f"server {len(server)} bytes, client {len(client)} bytes")


main()
