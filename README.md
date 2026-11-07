# Blink

A PostgreSQL driver in [Bend](https://github.com/bendlang/bend), modelled on
[Clunk](https://github.com/duanebester/clunk) and
[Skunk](https://github.com/typelevel/skunk). It needs nothing but Bend: no
libpq, no packages beyond Base. It's an early baseline: local TCP, trust
auth and simple queries.

## Design: bytes → messages → records are pure transforms

```
           ┌──────────────────────────── pure ─────────────────────────────┐
 socket ─▶ │ bytes ─▶ frames ─▶ backend messages ─▶ session ─▶ replies/rows │ ─▶ caller
 socket ◀─ │                                bytes to send ◀─┘               │
           └────────────────────────────────────────────────────────────────┘
                         ▲ blink/io.bend: receive, take, send ▲
```

| Module | Does |
|---|---|
| [`bytes`](blink/bytes.bend) | Big-endian ints, C strings, UTF-8 |
| [`frame`](blink/frame.bend) | bytes → frames: a fold whose state carries across reads |
| [`wire`](blink/wire.bend) | Frontend builders; frames → `Backend` messages |
| [`rows`](blink/rows.bend) | Cells → values by type OID; untyped records, and typed rows where `Row(schema)` computes the Bend type |
| [`session`](blink/session.bend) | The protocol state machine: `react(Session, Backend)`. `Conn` adds the framer, so a read is `receive(conn, bytes)`, then `take` the bytes to send |
| [`io`](blink/io.bend) | The only effects: `run(host, port, user, database, queries)` |

[`LAWS.bend`](LAWS.bend) states facts about the pure core and
[`PROOF.bend`](PROOF.bend) proves them; Bend's compiler checks both. For
example, `feed_split`: how TCP cuts the stream never changes the frames.

## Quick start

Install [Bend 2.0.40](https://github.com/bendlang/bend/releases/tag/v2.0.40)
(`curl -fsSL https://bend-lang.com/install.sh | sh`) and, for native
builds, clang 14+. Start a PostgreSQL with trust auth:

```sh
docker run -d -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17
export PGUSER=postgres PGDATABASE=postgres
```

A system PostgreSQL works too, with a `host all <user> 127.0.0.1/32 trust`
line in `pg_hba.conf`. Blink reads `PGHOST` (an IPv4 address, default
`127.0.0.1`), `PGPORT`, `PGUSER` and `PGDATABASE`.

[`examples/query.bend`](examples/query.bend) prints rows as `psql -qAt` does;
errors go to stderr with exit code 1:

```sh
bend examples/query.bend "SELECT 1 AS one, 'héllo' AS t, NULL AS n, true AS b"
# 1|héllo||t
bend examples/query.bend -- --replies "SELECT 1 AS a"   # every reply
bend examples/query.bend -o build/query && ./build/query "SELECT now()"   # native
```

From Bend:

```python
import Base
import ./blink/io.bend as Blink
import ./blink/session.bend as S

def main() -> IO(Unit):
  do IO<Unit>:
    rs : List<&2, S.Reply> <- Blink.run("127.0.0.1", 5432, "postgres", "postgres", ["SELECT 1 AS one"])
    List.for_each(~&2, ~S.Reply, ~(r => IO.print(S.show(r))), rs)
```

`run` returns the replies in order (`Columns`, a `Row` per row, `Complete`
per statement); an `Error` ends only its own query, and `Closed` means the
connection failed. [`examples/cities.bend`](examples/cities.bend) is a complete
program: it matches rows by shape and folds over them.

## Test

```sh
scripts/test.sh
```

It checks the laws, replays a recorded session
([`tests/fixtures`](tests/fixtures)) through the pure core on both lanes, and,
if a server is reachable, compares Blink with `psql` on live queries
(`BLINK_LIVE=1` fails instead of skipping). GitHub Actions runs it against
PostgreSQL 17 on every push and pull request. `tests/fixtures/capture.py`
re-records the session as `PGUSER=trusty PGDATABASE=world`.

## Limitations

- IPv4 TCP only: Bend has no DNS, TLS, IPv6 or Unix sockets.
- Trust auth only; MD5 and SCRAM are next.
- Simple query protocol only: no parameters, batches, cancellation or LISTEN/NOTIFY.
- One connection per `run`, all replies held in memory; no streaming or pool.
- Values are text except bool and int2/int4 (Bend has no signed ints, U64 or F64 yet).
- About 7× slower than `psql` natively: 100k rows in 0.8 s.

[`docs/research.md`](docs/research.md) has the background on each.

## Next

MD5 and SCRAM in pure Bend, the extended protocol, streaming replies over a
`Chan`, a pool, LISTEN/NOTIFY, then speed.

## Credits

[Clunk](https://github.com/duanebester/clunk) and
[Skunk](https://github.com/typelevel/skunk) for the design. The UTF-8 decoder
in `blink/bytes.bend` comes from Bend's `demos/io_http_fetch` (Apache-2.0).
