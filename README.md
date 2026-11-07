# Blink

A PostgreSQL driver in [Bend](https://github.com/bendlang/bend), modelled on
[Clunk](https://github.com/duanebester/clunk) (which follows Scala's
[Skunk](https://github.com/typelevel/skunk)). Like Clunk, it needs nothing
but its language: no libpq, and no packages beyond Bend's Base library.

It is an early baseline. It talks to a local PostgreSQL over TCP with trust
auth, runs simple queries and decodes their rows. See
[Limitations](#limitations).

## The idea: bytes → messages → records are transforms

Every step from the socket to a row is a pure function, and only a thin
shell touches the network:

```
           ┌──────────────────────────── pure ─────────────────────────────┐
 socket ─▶ │ bytes ─▶ frames ─▶ backend messages ─▶ session ─▶ replies/rows │ ─▶ caller
 socket ◀─ │                                bytes to send ◀─┘               │
           └────────────────────────────────────────────────────────────────┘
                         ▲ blink/io.bend: receive, feed, send ▲
```

| Module | Stage | What it is |
|---|---|---|
| [`blink/bytes.bend`](blink/bytes.bend) | bytes | Big-endian ints, C strings, UTF-8 encode/decode, cuts of byte lists |
| [`blink/frame.bend`](blink/frame.bend) | bytes → frames | A byte-at-a-time fold whose state carries across reads, so messages split anywhere still frame whole |
| [`blink/wire.bend`](blink/wire.bend) | frames ↔ messages | Frontend builders (Startup, Query, Terminate) and backend decoding into a `Backend` sum type, one constructor per message |
| [`blink/rows.bend`](blink/rows.bend) | messages → records | Text-format values by type OID, untyped records (`List<Entry>`), and typed rows: `decode(schema, cells) : Row(schema)`, where `Row` computes a Bend type from the schema |
| [`blink/session.bend`](blink/session.bend) | the protocol | Clunk's state machine as `react(Session, Backend) -> Session`: messages in, bytes to send and `Reply`s out; runs a queue of queries one at a time |
| [`blink/io.bend`](blink/io.bend) | effects | `run(host, port, user, database, queries)`: connect, then receive → feed → react → send until the session is done |

Because the core is pure, laws about it are checked by Bend's compiler.
[`LAWS.bend`](LAWS.bend) states them and [`PROOF.bend`](PROOF.bend) proves
them. The main law is `feed_split`: for every byte list and framer state,
feeding `a` then `b` equals feeding `a ++ b`. In other words, how TCP cuts
the stream never matters. The other laws pin concrete encodings and
decodings.

## Requirements

- **Bend 2.0.40.** Install it with `curl -fsSL https://bend-lang.com/install.sh | sh`, then add `~/.bend/bin` to your `PATH`. The installer always installs the latest Bend, and Bend changes daily, so if a newer release breaks Blink, install 2.0.40 from its [release](https://github.com/bendlang/bend/releases/tag/v2.0.40). Running `bun bend2/main.ts` from a checkout of `bendlang/bend` at `v2.0.40` also works.
- **clang 14 or newer** for native builds. `bend file.bend` runs on Bend's JS lane without clang.
- **A local PostgreSQL** that listens on an IPv4 address and lets your user in with **trust** auth.
- **psql** (optional): the live tests compare Blink's output with it.

### A local PostgreSQL with trust auth

With Docker:

```sh
docker run -d --name blink-pg -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17
export PGUSER=postgres PGDATABASE=postgres
```

With a system PostgreSQL, add a trust line for your user on `127.0.0.1`
above the other lines in `pg_hba.conf`, then reload:

```sh
sudo -u postgres psql -c "CREATE USER blink" -c "CREATE DATABASE blink OWNER blink"
# pg_hba.conf, first line:
#   host  all  blink  127.0.0.1/32  trust
sudo -u postgres psql -c "SELECT pg_reload_conf()"
export PGUSER=blink PGDATABASE=blink
```

Blink reads the same environment variables as libpq. `PGHOST` must be an
IPv4 address and defaults to `127.0.0.1`. `PGPORT` defaults to 5432,
`PGUSER` to `$USER`, and `PGDATABASE` to the user.

## Run

[`examples/query.bend`](examples/query.bend) runs each argument as a query
and prints rows the way `psql -qAt` does: values joined by `|`, with NULL
empty. Errors go to stderr, and the exit code is 1 if any query failed.

```sh
bend examples/query.bend "SELECT 1::int4 AS one, 'héllo' AS t, NULL AS n, true AS b"
# 1|héllo||t

bend examples/query.bend "SELECT 1/0" "SELECT 'next'"
# next
# ERROR 22012: division by zero          (stderr; exit 1)

# every reply, not just rows (`--` keeps bend from reading the flag)
bend examples/query.bend -- --replies "SELECT 1 AS a; SELECT 'x' AS b"
# columns a:23
# row 1
# complete SELECT 1
# columns b:25
# row x
# complete SELECT 1

# a native binary
bend examples/query.bend -o build/query && ./build/query "SELECT now()"
```

From your own Bend program:

```python
import Base
import ./blink/io.bend as Blink
import ./blink/session.bend as S

def print_all(rs: List<&2, S.Reply>) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case r <> rest:
      do IO<Unit>:
        IO.print(S.show(r))
        print_all(rest)

def main() -> IO(Unit):
  do IO<Unit>:
    rs : List<&2, S.Reply> <- Blink.run("127.0.0.1", 5432, "blink", "blink", ["SELECT 1 AS one"])
    print_all(rs)   # columns one:23 / row 1 / complete SELECT 1
```

`run` returns every reply in order: `Columns`, then `Row` (a list of named
`Value`s) for each row, then `Complete` for each statement. An `Error`
replaces the rest of its query only. A `Closed` ends the list if the
connection fails. To get typed rows, decode a `Row`'s cells with
`rows.bend`'s `decode` and a schema such as `[Col.Int{}, Col.Text{}]`.

## Test

```sh
scripts/test.sh
```

The script runs three groups:

1. **Laws.** `bend PROOF.bend` must print `ALL PROOFS CHECK`. No server is needed.
2. **Replay.** [`tests/replay.bend`](tests/replay.bend) runs a recorded real session ([`tests/fixtures`](tests/fixtures)) through bytes → frames → messages → session, 7 bytes per read, on both the JS lane and a native build. Its output must equal [`tests/replay.expected`](tests/replay.expected), and the session must send exactly the bytes the recorded client sent. No server is needed.
3. **Live.** Against the server in your `PG*` variables, it compares `build/query` with `psql -qAt` on types, NULL, edge values, several statements, 10,000 rows and 100 catalog rows. It checks that an error fails only its own query and that the JS lane runs. Without a reachable server this group is skipped. Set `BLINK_LIVE=1` to make a missing server fail the run instead.

To record the fixture again, use `tests/fixtures/capture.py`. It is a dev
tool, and Blink itself needs no Python:
`PGUSER=… PGDATABASE=… python3 tests/fixtures/capture.py`.

## Limitations

These are known and deliberate for now. [`docs/research.md`](docs/research.md)
explains where each comes from.

- **Local, plaintext TCP only.** Bend's Base has no DNS, TLS, IPv6 or Unix sockets, and those are out of scope here. `PGHOST` must be an IPv4 literal such as `127.0.0.1`, and a Postgres that listens only on a Unix socket is unreachable.
- **Trust auth only.** Password, MD5 and SCRAM-SHA-256 requests end the session with `FATAL 28000 … supports trust only`. All of them can be written in pure Bend; the research measured SCRAM's PBKDF2 at about 5 ms native.
- **Simple query protocol only.** There are no parameters (Parse/Bind), no prepared statements, no batched portals or `fetch-size`, no cancellation, no transactions API beyond sending `BEGIN`/`COMMIT` as SQL, and no LISTEN/NOTIFY. `NotificationResponse` decodes but nothing delivers it.
- **One connection, one batch.** `run` opens a connection, runs its queries, closes it, and returns every reply at once: there is no streaming and no pool yet. A large result is held in memory: 100,000 rows take about 49 MB native and 500 MB on the JS lane.
- **Values are text, except bool and int2/int4.** Bend has no signed integers, U64 or F64 yet, so int8, numeric, floats, dates, bytea and the rest arrive as `Value.Text` with Postgres's text. Typed rows support `Int`, `Text` and `Bool`, and don't check OIDs against the schema.
- **Speed.** Bytes are one list cell each. 100,000 rows of three columns take about 0.75 s native and 3.6 s on the JS lane, where `psql` takes 0.11 s (2 vCPUs).
- **Long-lived loops count down fuel** (4,294,967,295 reads) because Bend requires termination.
- **Tracks Bend 2.0.40.** Bend changes daily, and Blink pins no version itself.

## Next

Roughly in order: MD5 and SCRAM auth in pure Bend; the extended protocol
(parameters, batched portals, cancellation) in the session; delivering
replies while they stream, through a `Chan`; a connection actor and pool;
LISTEN/NOTIFY; then work on the byte representation for speed. Clunk's tests
are the checklist of behaviour to match.

## Credits

- [Clunk](https://github.com/duanebester/clunk) and [Skunk](https://github.com/typelevel/skunk) for the design.
- The UTF-8 decoder in `blink/bytes.bend` comes from Bend's `demos/io_http_fetch` (Apache-2.0).
