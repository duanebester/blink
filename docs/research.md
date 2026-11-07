# Blink: Bend2 PostgreSQL driver feasibility

> This is the research report from 2026-11-07 that led to Blink, kept as it was written. The original is the Amp artifact [Blink: Bend2 PostgreSQL driver feasibility](https://ampcode.com/artifacts/blink-bend2-postgresql-driver-feasibility-0ef969bd-2d6b-46fc-bba2-1f8e7923abd7), written in thread [T-01a1b642-ad1b-7531-92ef-2f6327465924](https://ampcode.com/threads/T-01a1b642-ad1b-7531-92ef-2f6327465924). The spike it describes (`/tmp/spike`) became this repository's baseline: `blink/` holds it split into modules, and `LAWS.bend` holds its laws. Timings in the README come from the baseline, not from the spike.

**Verdict:** Feasible for a plaintext, IPv4, trust/MD5/SCRAM driver today. A throwaway spike in Bend 2.0.40 connected to Postgres 15 and returned decoded rows on both the C and JS lanes. Two things block a production driver for hosted Postgres: Bend has no TLS and no DNS. The rest is design work inside Bend's constraints.

Sources read: `bendlang/bend` at `ca77ef2` (2026-11-07) and `duanebester/clunk` at `62af483` (2026-11-07).

## Authoritative Bend2 sources

- **github.com/bendlang/bend** is the live repo. `HigherOrderCO/Bend2` now holds only a README that says "Bend 2 has moved" (moved 2026-09-16). It has 3,492 commits and several merges a day. The version is 2.0.40 (2026-11-05).
- In that repo:
  - `guide/GUIDE.md` is the language guide (`bend guide`).
  - `guide/EFFECTS.md` explains foreign C/JS effects.
  - `bend2/base.bend` is the whole standard library, including every IO effect.
  - `bend2/effs/*.c|js` hold the effect implementations.
  - `WONTFIX.txt` lists design limits and planned features.
  - `CHANGELOG.md` has the release notes.
- `bend-lang.com` hosts the installer and BendHub, the package hub.
- The repo's `AGENTS.md` says `bend2/bend.ts` is human-written and frozen for agents.

## Clunk, the reference

Clunk is a Clojure/ClojureScript driver with no runtime dependencies (about 2,400 lines of source) that runs on both the JVM and Node. Its layers line up with the "bytes → messages → records" lens:

| Layer | Clunk file | Shape |
|---|---|---|
| Framing | `framing.cljc` | Transducer: byte chunks → one view per complete backend message; handles messages split across reads |
| Message codec | `messages.cljc`, `codecs.cljc`, `message_socket.cljc` | Pure decoders by tag (R, S, K, Z, T, D, C, E, N, A, 1/2/3, n, s, I) and builders (Startup, Query, Parse/Bind/Describe/Execute/Close/Flush/Sync, Password, SASL) |
| Values | `oid_types.cljc` | **Text format only**: every column decodes from its UTF-8 text, keyed by type OID. Parameters are sent as text. |
| Rows | `core.cljc` `row-decoder` | RowDescription → per-column decoders built once → map per DataRow |
| Auth | `pw.cljc` | MD5 and SCRAM-SHA-256 without channel binding. Hashing uses platform crypto (JVM `MessageDigest`/`Mac`/`PBKDF2`, Node `crypto`). |
| Protocol state machine | `core.cljc` `on-message` | Phases new → startup → ready → failed/closed. One query at a time per connection with a FIFO queue. Batched portals (`Execute max_rows` + `Flush`, then `PortalSuspended` → next batch or `Close`+`Sync`). Error → `Sync`. |
| Effects / runtime | `byte_buffer_socket`, `tls`, `pool`, `async`, `node` | Socket, TLS (sslmode-style, direct negotiation), pool (lazy, max-size, replaces dead connections, dedicated LISTEN connection), cancel tokens, LISTEN/NOTIFY, core.async adapter |

Clunk's own pure/effect boundary is already clean. Bend makes that boundary mandatory: the type system forces it.

## Spike: verified end to end

Scratch code, not committed at the time: `pg.bend` (346 lines) and `laws.bend` (62 lines), under `/tmp/spike`. Local Postgres 15.19 with `trust` auth.

The spike is all pure code except the last layer:

1. **Encode:** a UTF-8 encoder, `be32`, and builders for StartupMessage and Query. Bytes are `List<&2, U32>`.
2. **Frame:** a byte-at-a-time `List.foldl` with an explicit `Rx` state record (tag, 4 length bytes, body countdown). State carries across reads, so this is the FS2 "decoder as a fold" shape.
3. **Decode:** RowDescription → column names, DataRow → `List<Maybe<String>>` (NULL is length `0xFFFFFFFF`), and a UTF-8 decode taken from Bend's fetch demo.
4. **Protocol:** `react(Sess, Frame) -> Sess` is a pure state machine. It emits the bytes to send and the log lines.
5. **IO shell:** `TCP.connect`, then a loop of `TCP.recv_bytes` → feed → react → `TCP.send_bytes`, about 70 lines.

Result on both lanes:

```
auth request 4
ready
one=1 t=héllo n=NULL
one=2 t=wörld n=NULL
done
```

Measured on a 2-vCPU orb:

- **100,000 rows** (`id, 'city-'||id, id*7`, about 2.4 MB): **0.84 s** for the C-lane binary (4 MB RSS) and 1.6 s on the JS lane (195 MB RSS). `psql` takes 0.11 s for the same query. So the naive list-of-bytes design is about 8× slower than C libpq. That is acceptable for a first version, and it is the main thing to optimise.
- **SHA-256 round throughput in pure Bend:** about 5 ns per round on C (52 M rounds in 0.27 s) and about 0.05 s for 524 k rounds on JS. PBKDF2-SHA-256 with 4,096 iterations is about 524 k rounds, so **SCRAM in pure Bend costs about 5 ms on C and about 50 ms on JS**. MD5 is cheaper. No crypto dependency is needed.
- **Laws work on the pure layer.** `law feed_split` says `feed(feed(st, a), b) == feed(st, a ++ b)`: the framer does not care how TCP cuts the stream. It is proven in 4 lines and checks. A sabotaged proof fails with a precise goal. This is the property Clunk's `framing_test` tests with examples, here proven for all inputs.
- **Typed records via dependent types.** A first-order schema `List<Col>` with `Row(cs) -> Type` and `decode(cs, cells) -> Row(cs)` checked and ran: `(Some{42}, Some{"héllo"}, None{}, Unit{})`. This is the Skunk `Codec`/`Decoder` idea in Bend's own terms.

## Verified capabilities (from source and runs)

- **TCP client:** `TCP.connect(ipv4, port)`, `send_bytes` and `recv_bytes` (raw 0..255, no UTF-8 mangling), and `try_*` variants with ms deadlines. Non-blocking, parked on an event loop.
- **Concurrency:** `IO.fork`/`IO.join`, `IO.spawn`, bounded `Chan.new(A, room)` with `send`/`recv`/`try_*`/`close`, and `IO.within` for timeouts. A computation waiting on a socket yields to the others, as in Node.
- **Integers:** `U32` with `and/or/xor/not/shl/shr` and `+ - * / %`, `U32.read`/`show`/`hex`, `IO.random_u32` (for SCRAM nonces), and `IO.now`.
- **Collections:** a string-keyed `Map`, plus `List`, `Array` (in-place, power-of-two size), and `String` (a cons list of code points).
- **Foreign effects:** a def whose body is `import "./x.c"` plus `import "./x.js"` adds a new IO effect on both lanes, and may reuse Base handle types such as `Socket`.
- **Outputs:** a native binary through clang (14 worked here), plus C, JS, and `.mjs` (pure defs only) that JS can import.

## Gaps and constraints

**Blockers for hosted Postgres (WONTFIX #846: "No DNS, TLS, crypto or HTTP in Base"):**

- **No TLS.** It has to be a foreign effect over OpenSSL on the C lane. The JS lane does its IO through `bun:ffi` libc calls on raw file descriptors, so TLS there is a separate, harder project.
- **No DNS.** `TCP.connect` takes only an IPv4 literal (`io_sys_addr` → `inet_pton(AF_INET)`). There is **no IPv6 and no Unix-domain socket** either, so a local Postgres on `/var/run/postgresql` is unreachable without a foreign effect.

**Language constraints that shape the design (verified):**

- **Closures are affine (callable once).** Skunk/Clunk-style codec values composed at runtime and reused per row will not work. Codecs must be first-order data, such as a schema list, interpreted by top-level defs, or templates (`~f`, compile-time and closed).
- **No `if`; `match` only on parameters or pattern-bound variables; no mutual recursion; termination is mandatory.** Every step that matches on a computed value needs a helper def or an extra parameter. Long-lived loops count down a `Nat` fuel (the demos use `4294967295n`) or are `@unsafe`, which the proof gate then flags.
- **No signed integers, U64, or F64** (U64/F64 are listed as SOON, #1027/#1120), and `Nat` caps at 2^48. Text format helps here. Map int8, float8, numeric, and negative int4 to `String` or a small custom `Int` type at first, as Clunk does on Node for int8 and numeric.
- **Handles are affine and there is no select.** One `Socket` cannot be read by one computation and written by another, and nothing waits on "socket or channel" at once. A connection actor that both reads replies and accepts new requests (and LISTEN/NOTIFY while idle) needs one of: polling with `try_recv` and short deadlines, a small foreign `Socket.dup` effect to split read and write handles, or a strict request/response loop that reads only while a query is in flight.
- **Bytes are `List<U32>`**, one heap cell per byte. This is fine for correctness and is where the 8× gap comes from.
- **No native library target** (#813, planned). Blink would ship as a Bend module or BendHub package that Bend programs import. JS can import its pure layer (`.mjs`) but not its IO.
- **No cancellation of blocking effects** (#1034). Clunk-style cancellation is still possible, because it is protocol-level (stop asking for batches, then `Close` + `Sync`). A real `CancelRequest` is also doable over a second `TCP.connect`.
- **Churn and ABI.** Bend ships several merges a day, and foreign effects use runtime internals with "no ABI promise; rebuild your effects with every update". Pin a Bend version.

**Unverified (plausible, not run):**

- Sending a `Socket` through `Chan(A)` to build a pool (`Chan.send` takes `-A: Type`, so it should type-check).
- MD5/SCRAM correctness against a real server; only the round throughput was measured.
- Whether `Bool.pick`'s strict arguments cost much in hot paths (the spike's NULL cell eagerly splits the rest of the row).
- The `--verdict` Lean kernel, which was not built here.

## Recommended starting approach

Build Blink as a pure core with a thin IO shell. Each stage is a Bend def with laws, and the shell only moves bytes.

1. **`Blink.Wire` (pure):** byte helpers (`be16`/`be32`, cstring, UTF-8 encode/decode), frontend builders, and backend message decode into a `Backend` sum type (one constructor per tag). Laws: framing is invariant to how the stream is chunked (done), decoding a built message returns it (round trip), and lengths are correct.
2. **`Blink.Frame` (pure):** the `Rx` fold from the spike, as a reusable streaming decoder.
3. **`Blink.Proto` (pure):** Clunk's `on-message` state machine as `step(State, Event) -> (State, Effects)`. Events are backend messages and user requests. Effects are bytes to send and rows, errors, or completions to deliver. Start with the startup/auth phases, the simple query, and the error → `Sync` rule. Then add the extended protocol with the unnamed statement and portal, and batched `Execute`, all in text format as Clunk does. Laws can state protocol invariants, such as "every request ends exactly once" and "`ReadyForQuery` frees the connection".
4. **`Blink.Auth` (pure):** MD5, then SHA-256, HMAC, PBKDF2, base64, and SCRAM in Bend. Test against RFC 7677 vectors, or prove them against vectors with `{==}`.
5. **`Blink.Row` (pure):** an OID → `Col` mapping and dependent `Row(schema)` decoding, plus an untyped `List<(name, Value)>` path that matches Clunk's maps.
6. **`Blink.IO` (effects):** start with one connection and a strict request/response loop. Then add a connection actor fed by a `Chan`, choosing among polling, a `Socket.dup` foreign effect, or request/response only. After that comes the pool (one actor per connection plus a dispatcher `Chan`) and LISTEN/NOTIFY on a dedicated connection.
7. **Defer** TLS and DNS (foreign C effects, C lane first), Unix sockets, binary format, and performance work on byte representation (for example, chunk-level slices or `Array`). For local development, connect to `127.0.0.1`. To reach hosted databases before TLS exists, use a local TLS-terminating sidecar.

Keep Clunk's tests as the behaviour checklist: the core, framing, listen, and pool tests, and the stress test's invariants.
