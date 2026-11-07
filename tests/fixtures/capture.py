#!/usr/bin/env python3
"""Records a real session's bytes for tests/replay.bend (a dev tool only;
Blink itself needs no Python). Connects with trust auth, runs QUERIES with
the simple query protocol, then EXTENDED with the extended one (Parse, Bind,
Describe, Execute, and Flush per batch or Sync), and writes what each side
sent:

  session.server.bin  every byte the server sent
  session.client.bin  every byte the client sent

tests/replay.bend connects as trusty to world, so record as them:

  PGUSER=trusty PGDATABASE=world python3 tests/fixtures/capture.py
"""
import os
import socket
import struct

QUERIES = [
    "SELECT 1::int4 AS one, 'héllo'::text AS t, NULL::text AS n, true AS b, -42 AS neg; SELECT 1/0",
    "SELECT 'after' AS a",
]

# (sql, params, fetch): None is NULL; fetch 0 is every row at once.
EXTENDED = [
    ("SELECT $1::int4 + 1 AS n, $2::text AS t, $3::text IS NULL AS isnull",
     ["41", "héllo 🐘", None], 0),
    ("SELECT g FROM generate_series(1, 5) g", [], 2),
    ("SELECT 1/(3-g) AS q FROM generate_series(1, 5) g", [], 2),
    ("SELECT $1::int4", ["x"], 2),
    ("", [], 2),
]


def message(tag, body):
    return tag + struct.pack("!I", len(body) + 4) + body


def cstring(s):
    return s.encode() + b"\0"


def extended(sql, params, fetch):
    """What Blink sends first for an extended query."""
    values = b"".join(struct.pack("!i", -1) if v is None
                      else struct.pack("!I", len(v.encode())) + v.encode() for v in params)
    return (message(b"P", b"\0" + cstring(sql) + struct.pack("!H", 0))
            + message(b"B", b"\0\0" + struct.pack("!HH", 0, len(params)) + values
                      + struct.pack("!H", 0))
            + message(b"D", b"P\0")
            + message(b"E", b"\0" + struct.pack("!I", fetch))
            + message(b"H" if fetch else b"S", b""))


class Server:
    """The server's messages, one at a time, recording every byte read."""

    def __init__(self, sock):
        self.sock, self.buf, self.seen = sock, b"", bytearray()

    def next(self):
        while len(self.buf) < 5 or len(self.buf) < struct.unpack("!I", self.buf[1:5])[0] + 1:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit("server closed the connection")
            self.seen.extend(chunk)
            self.buf += chunk
        size = struct.unpack("!I", self.buf[1:5])[0] + 1
        tag, self.buf = self.buf[:1], self.buf[size:]
        return tag

    def until(self, *tags):
        while (tag := self.next()) not in tags:
            pass
        return tag


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    user = os.environ.get("PGUSER", os.environ.get("USER", "postgres"))
    db = os.environ.get("PGDATABASE", user)
    sock = socket.create_connection((os.environ.get("PGHOST", "127.0.0.1"),
                                     int(os.environ.get("PGPORT", "5432"))))
    params = b"".join(s.encode() + b"\0" for s in
                      ["user", user, "database", db, "client_encoding", "UTF8"]) + b"\0"
    startup = struct.pack("!II", len(params) + 8, 196608) + params
    server, client = Server(sock), bytearray()

    def send(m):
        client.extend(m)
        sock.sendall(m)

    send(startup)
    server.until(b"Z")
    for q in QUERIES:
        send(message(b"Q", q.encode() + b"\0"))
        server.until(b"Z")
    for sql, params, fetch in EXTENDED:
        send(extended(sql, params, fetch))
        # A batched query asks for each next batch, and syncs when it ends.
        while fetch and server.until(b"s", b"C", b"I", b"E") == b"s":
            send(message(b"E", b"\0" + struct.pack("!I", fetch)) + message(b"H", b""))
        if fetch:
            send(message(b"S", b""))
        server.until(b"Z")
    send(message(b"X", b""))
    sock.close()
    server = server.seen
    with open(os.path.join(here, "session.server.bin"), "wb") as f:
        f.write(server)
    with open(os.path.join(here, "session.client.bin"), "wb") as f:
        f.write(client)
    print(f"server {len(server)} bytes, client {len(client)} bytes")


main()
