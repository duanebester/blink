# What to take from Skunk

[Skunk](https://github.com/typelevel/skunk) is effectful (cats-effect and
fs2), but many of its best ideas are pure data and functions. This note
records which ones fit Blink's design, where bytes → messages → records are
pure transforms and `blink/io.bend` is the only effectful module. It comes
from a review of Blink at `3bf4316` against Skunk at `1045d3b`. The sketches
it mentions were type-checked with `bend --check-only` in a scratch copy;
none of them are in the repo yet.

Skunk paths are relative to `modules/core/shared/src/main/scala/`.

## Fixed after the review

- `COPY … FROM STDIN` hung forever; `COPY … TO STDOUT` dropped its data.
- After a cancel, Blink waited forever if the cancel never landed.
- A wrong SCRAM signature was reported as the server's `FATAL 28000`; it's
  now `Reply.Refused`.

## Still open

- **Replies lose information.** There is no boundary between queries, so
  two one-statement queries give the same replies as one two-statement
  query. ReadyForQuery's transaction status and ParameterStatus are dropped.
- **Typed rows can't be reached from `run`.** `Reply.Row` carries untyped
  entries, and `R.decode` reads NULL and an unparseable value (such as an
  int8 past U32) both as `None`. `Row(schema)` is built from `&`, which is
  affine, so typed rows can't be stored in lists.
- **The session has no idle state.** `connect` takes every query up front
  and terminates when the queue is empty, so the next query can't depend on
  earlier results. This blocks cursors, transactions and channels.
- **`phase: U32`** uses the magic numbers 0–3, so illegal states can be
  represented. A `Phase` sum type would fix that.
- **Protocol policy in the shell.** SCRAM nonce formatting and "a timeout
  means cancel" live in `io.bend`. `tests/replay.bend` re-implements the
  loop rather than sharing it.
- **Errors keep only S, C and M.** Position, detail, hint, the
  constraint, table and column fields, and the unlocalized severity (V) are
  dropped.
- **Parse sends no parameter types**, so the server infers them all.
- **`Query.Extended{sql, params, fetch, timeout}`** mixes *what* to run with
  *how*: two positional U32s that are easy to swap.
- **Only `feed_split` is universal.** The other laws are ground examples.
  Universal session laws also check with `{==}` (verified: "a failed session
  ignores every message", "an error before Sync sends exactly one Sync").

## Skunk ideas in pure Bend

| Skunk | What it does | Pure Bend version | Status |
|---|---|---|---|
| `Codec`, `Encoder`, `Decoder` | Encode and decode text, carry OIDs | `Col.Int4/Text/Bool/Opt{c}`, NOT NULL by default; `encode`; `decode -> Result<DecodeError, Row(cs)>`; `oid(c)`; rows built from `+Sigma` so they're Data | Verified |
| twiddles, `.to[CaseClass]` (`util/Twiddler.scala`) | Map tuples to records | A template `map_rows(~B, ~cs, ~f, rows)`; `f` and the schema must be closed terms | Verified |
| `Fragment`, `sql"…"` | SQL with typed holes; composition renumbers `$n` | `Part.Sql{s} \| Part.Param{c}`; `render` numbers `$n`; the argument type is computed as `Row(params(f))`, so a wrong argument is a compile error. No interpolator: Bend has no macros | Verified |
| `Query[A, B]`, `Command[A]` | Typed input and output | `Stmt{frag, cols}`; `bind(stmt, args: Args(stmt), fetch) -> S.Query`; the session stays untyped | Verified |
| `net/protocol/ParseDescribe.scala` | Parse with parameter OIDs | `W.parse(sql, oids(params))` | Trivial |
| `Describe.scala`, `util/Typer.scala` | Check a statement against the server | `Query.Describe`; decode ParameterDescription `t` and NoData `n`; a pure `check(want, got) -> List<Mismatch>` | `check` verified |
| `BufferedMessageSocket` | Splits asynchronous messages from the exchange | Session fields: `params`, `tx`; Notification as a reply | Feasible |
| `data/Completion.scala` | Parsed command tag | `Completion{verb, rows: Maybe<U32>}`, not an 80-case enum | Verified (U32 caveat: Postgres row counts are 64-bit) |
| `data/TransactionStatus.scala` | Idle, active or failed | `Tx.Idle/Active/Failed`, reported per query | Verified |
| `Transaction.scala` | Begin, commit or roll back | `[BEGIN] ++ qs ++ [COMMIT]` (Postgres turns that COMMIT into ROLLBACK after an error); a rollback the client decides needs an idle session | Caveats |
| `Channel.scala` | LISTEN/NOTIFY | Decoding `A` is pure; delivery needs a long-lived loop, and Bend can't wait on a socket and a `Chan` at once | Caveats |
| `Cursor.scala` | Caller-driven `fetch(n)` | Pause at PortalSuspended until a `More{n}` or `Stop` event | Needs the event API |
| `exception/PostgresErrorException.scala`, `SqlState` | Every error field, a position caret | An `ErrorFields` record of Maybes; a pure `caret(sql, position)`; SqlState as string constants | Feasible |
| `Session.scala` | `execute`, `unique`, `option`, `stream`, `prepare` | Pure shapers `rows`, `unique`, `option`, `completion`; later an interactive `open`, `submit`, `next` | Part needs events |
| `util/StatementCache.scala` | Named prepared statements | Names keyed by SQL (Base's `Map` is keyed by string) | Later |
| `net/SSLNegotiation.scala` | TLS | The SSLRequest bytes are pure; TLS isn't | Blocked: no TLS in Bend |

## Order

1. **Faithful replies** (M): raw `Row{cells}` with records as a view,
   `Ready{tx}` per query, ParameterStatus kept. Prove that boundaries and
   status survive.
2. **Typed codecs** (M, additive): `Opt`, rows as Data, `encode`, and a
   `decode` that returns a Result. Prove NULL isn't read as bad text, and
   `length(encode(cs, row)) == length(cs)` by induction.
3. **`Stmt`, `Fragment` and `bind`, with OIDs in Parse** (M). Rewrite
   `cities.bend` with types.
4. **Error fields and `Completion`** (S/M). Check live that a syntax error
   returns a position.
5. **A `Phase` sum type and universal session laws** (M).
6. **An event-driven pure driver** (M/L):
   `step(Conn, Event{Bytes, Timeout, Eof, Submit, More, Stop})` plus
   `actions(Conn)`. `io.bend` becomes a plain interpreter, and replay shares
   the same loop. This unlocks cursors, transactions and channels.
7. **Statement checking** against Describe (M). Test live an int4 codec
   against an int8 column.

## What not to copy

- **cats-effect machinery:** `Resource`, fibers, `Ref`, `Queue`, `Deferred`
  and the `Exchange` mutex. A pure state machine already serializes the
  exchange.
- **The pull-style `MessageSocket.expect` and its history buffer.** They
  are the opposite of a push-style `react`.
- **Typeclass instances and closures composed at runtime.** Bend's closures
  are affine, so use first-order data and templates.
- **The 80-case `Completion` and 250-case `SqlState` enums.**
- **Dynamic `Typer` lookups, telemetry, `Origin` (macros), redaction, and a
  pool** before sessions are long-lived.
- **Do keep Skunk's split** between *what* runs (`Query`) and *how*
  (`stream(chunkSize)`): move `fetch` and `timeout` out of the statement.
