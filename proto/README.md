# Prototype: Blink on a shared Base `Bytes` (bendlang/bend#1573)

Not for main. `bend-shared-bytes.patch` adds a byte value to Bend 2.0.40's
Base, and Blink's DataRow cells become slices of the read they came in.
Blink itself has no foreign code, and every law in LAWS.bend is proven
(`bend PROOF.bend --verdict` passes).

    git clone https://github.com/bendlang/bend && cd bend && git checkout v2.0.40
    git apply .../blink/proto/bend-shared-bytes.patch
    BEND="bun $PWD/bend2/main.ts" .../blink/scripts/test.sh

## The design

    type Bytes is Data:
      Bytes{data: List<&2, U32>}

Bend already uses this pattern for U32 (a Word in the theory, a machine
int when compiled) and for Array (a tree in the theory, a flat block when
compiled). In the theory, Bytes is its list. Each operation is defined in
base.bend on that list, and that definition is what it means. The JS lane
runs those definitions. The C lane runs a native intrinsic for each one,
listed in comp.ts's OPERATIONS.

- `Bytes.of_list` (values mod 256), `empty`, `freeze(Array<U32>, n)` (the
  builder), `to_list`, `length`
- `slice(b, o, n)` = `take(n, drop(o, data))`, `take`, `drop`: O(1), and
  the result shares the block
- `get`, `be16`, `be32` (0 past the end), `concat`, `eq`, `utf8` (WHATWG
  replacement policy)
- `copy`: the identity in the theory. Compiled, it gives the bytes a block
  of their own, so a small slice kept long need not keep its whole read
  alive.
- `TCP.recv_buf` / `TCP.try_recv_buf` return `Maybe<&1, Bytes>` and fill
  a block straight from the socket (the new `io_bytes` sits beside
  `io_list`).

Because Bytes is Data, it can be copied, compared, and stored in Frames,
Replies, and rows. The previous prototype's `Bytes{len, buf: Array<U32>}`
was a single-owner Type and could do none of these.

## What the 2.0.40 runtime allowed

- **A native shared block: yes, on the host.** A Bytes value is a 4-word
  ARR block `[blob, off, len, 0]`. Its blob is a BUF block that holds the
  byte count in word 0 and the bytes packed 8 per word after it. Both are
  wrapped in Bend's existing reference count at birth, as a Chan's block
  is. Slices and copies `term_keep` the blob, and `term_drop` frees it with
  its last reference. No new memory machinery was needed.
- `bytes_cut` reuses a slice's block in place when its count is 1, so
  `drop` on a uniquely held rest allocates nothing. `concat` with an empty
  side costs nothing, which is the framer's case after a read that ends on
  a message boundary.
- Construction `Bytes{xs}` compiles to a packing loop and a match compiles
  to an unpacking loop, so code that treats Bytes as its list still runs
  natively. `Bytes{xs}` with a value past 255 stops the program with a new
  error (`ERR_BYTE`), as a Nat out of range does. `of_list` masks instead.
- **Not reachable:** the GPU/device path. The helpers are `#if !DEVICE`,
  so a Bytes value can't cross to a device lane. JS has no native form: it
  runs the list theory (fine for tests, slow for data).
- The native ops are trusted, not verified against the theory, which is
  the same trust Bend already places in U32's ops. As evidence, JS (the
  theory) and C agree on a random-op differential test over 64 parallel
  lanes, and 4M slice/concat/copy iterations keep RSS flat at 2.4 MB.

## Blink on it

- frame.bend frames whole messages: `Rx{rest: Bytes, done}`. A step reads
  a 5-byte header and slices the body. A DataRow's cells are
  `Maybe<Bytes>` slices of that body, so no cell byte is copied. The bytes
  after the last whole message stay as a slice, and the next read is
  concatenated to them.
- `Frame.Row`, `Backend.Row`, `Item.Row`, and rows.bend's `Value.Text`
  carry Bytes. Ints parse from `Bytes.utf8`, bools read `Bytes.get`.
- io.bend reads with `recv_buf(s, 65528)`, so one read's block plus its
  header fits one class-13 heap block. `receive_buf` is the connection's
  entry point. `receive(c, list)` = `receive_buf(c, Bytes.of_list(list))`
  is what laws and tests use.

## Laws

All of main's laws hold and are proven. Three changed:

- `feed_split` and `receive_split` say the same thing over the list view
  (`F.feed(rx, list)`), for every Rx, including an Rx whose rest is any
  Bytes. `feed_split` now marks `a` and `b` `+`, as `receive_split`
  already did, because its proof uses each twice. The proof is new: the
  framer cuts whole messages, so the induction is on the fuel (one step per
  message, with fuel past the length always enough) rather than on bytes.
  It rests on take/drop of an append and on `mask` distributing over an
  append. `receive_split` reuses main's argument with a new `cut_app`.
- The `feed_frames` and `typed_row` vectors write their cells as
  `Some{Bytes{[...]}}`.

New laws, all proven:

- `bytes_slice`: `to_list(slice(b, o, n)) == take(n, drop(o, to_list(b)))`
- `bytes_slice_length`: length is `min(n, length(b) - o)`
- `bytes_concat`: concat is append
- `bytes_copy`: `copy(b) == b`

tests/split.bend also runs `receive_split` on the recorded session at every
cut (1285 cuts) on both lanes, so the native block is checked against the
law, not only the theory.

## Numbers

One connection on a 2-core orb against local Postgres 17 (SCRAM). Wall
time is the best of 3; RSS is the maximum.

| query | main | first proto (Array buffer) | shared Bytes |
|---|---|---|---|
| login: `SELECT 1` | 0.013 s, 2.7 MB | 0.012 s, 2.7 MB | 0.011 s, 2.7 MB |
| a: 100k × (int, text, bool) | 0.262 s, 65 MB | 0.193 s, 66 MB | 0.150 s, 38 MB |
| b: 100k × 100-char text | 0.726 s, 244 MB | 0.515 s, 245 MB | 0.083 s, 30 MB |
| c: 1M × (int, text, bool) | 2.953 s, 670 MB | 1.811 s, 671 MB | 1.362 s, 353 MB |

b is now at the earlier upper bound (0.064 s) and near bend-kit-postgres
(0.054 s), both measured on another orb. c is still per-row bound: perf
shows `term_drop` and `span_fade` on Blink's per-row structures (the
Frame, the cell list, the Maybe per cell, the Reply), the same work main
does, and not Bytes. Each cell costs a 2-word slice block, a refcount cell,
and an atomic increment on the blob.
