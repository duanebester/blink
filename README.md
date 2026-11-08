# Blink

> [!WARNING]
> This repo was entirely vibe coded. Don't use it for anything but hacking
> around: it is not reviewed, not secure, and not fit for real data.

A PostgreSQL driver in [Bend](https://github.com/bendlang/bend), modelled on
[Clunk](https://github.com/duanebester/clunk) and
[Skunk](https://github.com/typelevel/skunk). It needs nothing but Bend: no
libpq, no packages beyond Base, no foreign code. It's an early baseline:
local TCP, password auth (trust, cleartext, MD5, SCRAM-SHA-256), simple
queries, and extended ones with parameters, batched rows and cancellation.

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
| [`frame`](blink/frame.bend) | bytes → frames: a fold whose state carries across reads; DataRows come out cut into cells |
| [`wire`](blink/wire.bend) | Frontend builders; frames → `Backend` messages |
| [`crypto`](blink/crypto.bend) | MD5, SHA-256, HMAC, PBKDF2, base64 |
| [`auth`](blink/auth.bend) | Each auth request's answer, SCRAM included: `answer(code, data, login)` |
| [`rows`](blink/rows.bend) | Cells → values by type OID; untyped records, and typed rows where `Row(schema)` computes the Bend type |
| [`session`](blink/session.bend) | The protocol state machine: `react(Session, Backend)`. `Conn` adds the framer, so a read is `receive(conn, bytes)`, then `take` the bytes to send. Rows stay raw until `replies`, which decodes them in parallel |
| [`io`](blink/io.bend) | The only effects: `run(host, port, user, password, database, queries)`, and a CancelRequest when a query times out |

[`LAWS.bend`](LAWS.bend) states facts about the pure core and
[`PROOF.bend`](PROOF.bend) proves them; Bend checks the proofs, and
`--verdict` rechecks them with BendTT's kernel, which has a proof in Lean.
Most hold for every input. For example, `receive_split`: for every
connection and every way TCP cuts the stream into reads, the connection
ends in the same state, with the same replies and bytes to send;
`decode_keeps_order`: parallel decoding gives exactly the sequential result,
for every lane count; and `scram_signature_checked`: SCRAM finishes only if
the server's signature is exactly the expected one. The rest are byte-exact
vectors.

## Quick start

Install [Bend 2.0.40](https://github.com/bendlang/bend/releases/tag/v2.0.40)
(`curl -fsSL https://bend-lang.com/install.sh | sh`) and, for native
builds, clang 14+. Start a PostgreSQL:

```sh
docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=blink postgres:17
export PGUSER=postgres PGPASSWORD=blink PGDATABASE=postgres
```

Blink reads `PGHOST` (an IPv4 address, default `127.0.0.1`), `PGPORT`,
`PGUSER`, `PGPASSWORD` and `PGDATABASE`.

[`examples/query.bend`](examples/query.bend) prints rows as `psql -qAt` does;
errors go to stderr with exit code 1:

```sh
bend examples/query.bend "SELECT 1 AS one, 'héllo' AS t, NULL AS n, true AS b"
# 1|héllo||t
bend examples/query.bend -- --replies "SELECT 1 AS a"   # every reply
bend examples/query.bend -- --param 41 --null 'SELECT $1::int4 + 1, $2::text IS NULL'
# 42|t
bend examples/query.bend -- --fetch 1000 "SELECT * FROM generate_series(1, 100000)"   # 1000 rows per batch
bend examples/query.bend -- --timeout 500 "SELECT pg_sleep(60)"   # cancelled after 0.5 s of silence
mkdir -p build && bend examples/query.bend -o build/query && ./build/query "SELECT now()"   # native
```

From Bend:

```python
import Base
import ./blink/io.bend as Blink
import ./blink/session.bend as S

def main() -> IO(Unit):
  do IO<Unit>:
    rs : List<&2, S.Reply> <- Blink.run("127.0.0.1", 5432, "postgres", "blink", "postgres", [
      S.Query.Simple{"SELECT 1 AS one; SELECT 2 AS two"},
      S.Query.Extended{"SELECT $1::text AS t", [Some{"héllo"}], 0, 0}])
    List.for_each(~&2, ~S.Reply, ~(r => IO.print(S.show(r))), rs)
```

A `Simple` query may hold several statements. An `Extended{sql, params,
fetch, timeout}` is one statement, with `params` as `$1, $2…` (`None` is
NULL), never spliced into the SQL. With `fetch > 0`, rows come `fetch` at a
time. With `timeout > 0`, a server that stays silent that long gets a
CancelRequest, and no more batches are asked for; if it stays silent
that long again, the connection closes.

`run` returns the replies in order (`Columns`, a `Row` per row, a `Copy`
per `COPY … TO STDOUT` line, `Complete` per statement). An `Error` is the
server's and ends only its own query; `Refused` is Blink rejecting the
server during login (say, a wrong SCRAM signature); `Cancelled` marks a
timeout, and `Closed` means the connection failed. [`examples/cities.bend`](examples/cities.bend) is a complete
program: it matches rows by shape and folds over them.

## Test

```sh
scripts/test.sh
```

It checks the laws, replays a recorded session
([`tests/fixtures`](tests/fixtures)) through the pure core, checks the hashes
and SCRAM against RFC vectors ([`tests/auth.bend`](tests/auth.bend)), and, if
a server is reachable, compares Blink with `psql` on live queries
(`BLINK_LIVE=1` fails instead of skipping; `BLINK_AUTH="user:password ..."`
also tests those logins). [`tests/aggregates.bend`](tests/aggregates.bend)
fetches 100,000 rows of mixed types, simple and in batches, and checks the
counts, sums and an MD5 of every value against Postgres's own aggregates.
`BLINK_VERDICT=1` adds `--verdict`, which needs Lean 4.34.0. GitHub Actions
runs it all against PostgreSQL 17, over SCRAM and MD5, on every push and pull
request. `tests/fixtures/capture.py`
re-records the session as `PGUSER=trusty PGDATABASE=world`.

## Performance

Against Postgres 17 over SCRAM on a 12-core Ryzen AI 9 HX 370, best of 5.
Python and Node times exclude interpreter startup but include loading the
driver; Blink's include its whole process. Bulk numbers use all cores.

| | Login + `SELECT 1` | 1,000 small queries | 100k rows × 3 cols | 100k × 100-char text | 1M × 3 cols |
|---|---|---|---|---|---|
| asyncpg | 20 ms | 100 ms | 0.05 s | 0.05 s | 0.31 s |
| postgres.js | 27 ms | 57 ms | 0.05 s | 0.07 s | 0.22 s |
| psycopg 3 (libpq) | 47 ms | 64 ms | 0.08 s | 0.08 s | 0.37 s |
| Blink, native | **7–10 ms** | **29–42 ms** | 0.20 s | 0.42 s | 1.8 s |

Blink is quick to connect and to run small queries, and 4–9× slower on
bulk rows; it holds every row until the end, so 1M rows take 685 MB
against the others' 170–280 MB. Rows decode in parallel lanes. The JS
build is about 6× slower than native.

## Limitations

- IPv4 TCP only: Bend has no DNS, TLS, IPv6 or Unix sockets.
- SCRAM without SASLprep or channel binding (as libpq over plain TCP); use ASCII passwords.
- Extended queries use the unnamed statement (no prepared-statement cache), text format only.
- Cancellation is by timeout: there's no streaming yet, so nothing else could fire it.
- No LISTEN/NOTIFY, and `COPY … FROM STDIN` fails (Blink has no data to send).
- One connection per `run`, all replies held in memory; no streaming or pool.
- Values are text except bool and int2/int4 (Bend has no signed ints, U64 or F64 yet).
  Text stays UTF-8 bytes (`Value.Text{bytes}`) until read with `B.text`.
- Slow on bulk rows (below): Bend's sockets hand over a list cell per byte,
  and values stay lists of bytes.

[`docs/research.md`](docs/research.md) has the background on each, and
[`docs/skunk.md`](docs/skunk.md) what to take from Skunk next.

## Next

Streaming replies over a `Chan` (so a reader can cancel or stop early),
text values kept as bytes until read, a pool, then LISTEN/NOTIFY.

## Credits

[Clunk](https://github.com/duanebester/clunk) and
[Skunk](https://github.com/typelevel/skunk) for the design. The UTF-8 decoder
in `blink/bytes.bend` comes from Bend's `demos/io_http_fetch` (Apache-2.0).
