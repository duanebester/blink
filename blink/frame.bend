# Framing: bytes -> frames. TCP delivers a stream, not messages: one read
# may hold several messages, the end of one, or part of a header. Bytes
# arrive in a flat buffer that starts at a message boundary: the shell puts
# the bytes left over from the last read (rest) in front of each read. The
# framer reads each 5-byte header, cuts the whole messages, and keeps what
# is left for next time, so how the stream was cut never matters
# (LAWS.bend: feed_split). Pure.
import Base
import ./bytes.bend as B

# A backend message: its tag byte and its body, without the length. A
# DataRow comes already cut into its cells (None is NULL), straight from
# the buffer: rows are most of the bytes.
type Frame is Data:
  Frame{tag: U32, body: List<&2, U32>}
  Frame.Row{cells: List<&2, Maybe<&2, List<&2, U32>>>}

# rest is the bytes after the last whole message; done is newest-first.
type Rx is Data:
  Rx{rest: List<&2, U32>, done: List<&2, Frame>}

def new() -> Rx:
  Rx{Nil{}, Nil{}}

# ---- a DataRow's cells: a count, then each cell's length (-1 is NULL)
# and bytes

type Cells is Data:
  Cells{at: U32, cells: List<&2, Maybe<&2, List<&2, U32>>>}

def cell.some(+i: U32, +len: U32, cs: List<&2, Maybe<&2, List<&2, U32>>>,
  r: Array<U32> & List<&2, U32>) -> Array<U32> & Cells:
  (a, xs) = r
  (a, Cells{((i + 4 : U32) + len : U32), Some{xs} <> cs})

def cell.len(null: Bool, +i: U32, +len: U32, a: Array<U32>,
  cs: List<&2, Maybe<&2, List<&2, U32>>>) -> Array<U32> & Cells:
  match null:
    case True{}:
      (a, Cells{(i + 4 : U32), None{} <> cs})
    case False{}:
      cell.some(i, len, cs, B.slice(a, (i + 4 : U32), len))

def cell(+i: U32, cs: List<&2, Maybe<&2, List<&2, U32>>>, r: Array<U32> & U32) -> Array<U32> & Cells:
  (a, +len) = r
  cell.len(U32.is_eq(len, 4294967295), i, len, a, cs)

# j cells, newest-first.
def cells(j: Nat, r: Array<U32> & Cells) -> Array<U32> & Cells:
  match j:
    case 0n:
      r
    case 1n+q:
      (a, c) = r
      match c:
        case Cells{+i, cs}:
          cells(q, cell(i, cs, B.at32(a, i)))

def row.got(r: Array<U32> & Cells) -> Array<U32> & Frame:
  (a, c) = r
  match c:
    case Cells{i, cs}:
      (a, Frame.Row{List.reverse(&2, Maybe<&2, List<&2, U32>>, cs)})

# The count is the first two bytes of the word at i.
def row.n(+i: U32, r: Array<U32> & U32) -> Array<U32> & Frame:
  (a, w) = r
  row.got(cells(U32.to_nat((w >> 16n : U32)), (a, Cells{(i + 2 : U32), Nil{}})))

# ---- whole messages

# What is at a position: a whole message and where the next starts, or not
# enough bytes for one.
type Step is Data:
  Step.Frame{frame: Frame, next: U32}
  Step.Stop{at: U32}

def step.got(+next: U32, r: Array<U32> & Frame) -> Array<U32> & Step:
  (a, f) = r
  (a, Step.Frame{f, next})

def step.body(tag: U32, r: Array<U32> & List<&2, U32>) -> Array<U32> & Frame:
  (a, body) = r
  (a, Frame{tag, body})

def step.kind(row: Bool, tag: U32, +i: U32, +len: U32, a: Array<U32>) -> Array<U32> & Frame:
  match row:
    case True{}:
      row.n((i + 5 : U32), B.at32(a, (i + 5 : U32)))
    case False{}:
      step.body(tag, B.slice(a, (i + 5 : U32), (len - 4 : U32)))

def step.tag(+i: U32, +len: U32, r: Array<U32> & U32) -> Array<U32> & Step:
  (a, +tag) = r
  step.got(((i + 1 : U32) + len : U32), step.kind(U32.is_eq(tag, 68), tag, i, len, a))

def step.whole(short: Bool, a: Array<U32>, +i: U32, +len: U32) -> Array<U32> & Step:
  match short:
    case True{}:
      (a, Step.Stop{i})
    case False{}:
      step.tag(i, len, Array.get(U32, a, i))

# The length counts its own four bytes; less is malformed, read as 4.
def step.len(+i: U32, +n: U32, r: Array<U32> & U32) -> Array<U32> & Step:
  (a, got) = r
  +len = U32.max(got, 4)
  step.whole(U32.is_lt((n - i : U32), (len + 1 : U32)), a, i, len)

def step.have(short: Bool, a: Array<U32>, +i: U32, +n: U32) -> Array<U32> & Step:
  match short:
    case True{}:
      (a, Step.Stop{i})
    case False{}:
      step.len(i, n, B.at32(a, (i + 1 : U32)))

# The step at i of a[0 .. n], for i <= n.
def step(a: Array<U32>, +i: U32, +n: U32) -> Array<U32> & Step:
  step.have(U32.is_lt((n - i : U32), 5), a, i, n)

def cut.end(done: List<&2, Frame>, r: Array<U32> & List<&2, U32>) -> Rx:
  (a, rest) = r
  Rx{rest, done}

def cut.stop(+n: U32, a: Array<U32>, st: Step, done: List<&2, Frame>) -> Rx:
  match st:
    case Step.Stop{+i}:
      cut.end(done, B.slice(a, i, (n - i : U32)))
    case Step.Frame{f, +i}:
      cut.end(f <> done, B.slice(a, i, (n - i : U32)))

# A message is at least 5 bytes, so n / 5 + 1 steps are enough.
def cut.go(j: Nat, +n: U32, r: Array<U32> & Step, done: List<&2, Frame>) -> Rx:
  match j:
    case 0n:
      (a, st) = r
      cut.stop(n, a, st, done)
    case 1n+q:
      (a, st) = r
      match st:
        case Step.Stop{+i}:
          cut.stop(n, a, Step.Stop{i}, done)
        case Step.Frame{f, +i}:
          cut.go(q, n, step(a, i, n), f <> done)

# A read's buffer in: a[0 .. n] is the rest from the last read (which the
# caller took with rest) followed by the new bytes.
def feed_buf(rx: Rx, a: Array<U32>, +n: U32) -> Rx:
  match rx:
    case Rx{rest, done}:
      cut.go(U32.to_nat(((n / 5 : U32) + 1 : U32)), n, step(a, 0, n), done)

# The bytes left over, for the next read to start with, and the framer
# without them.
def rest(rx: Rx) -> List<&2, U32> & Rx:
  match rx:
    case Rx{rest, done}:
      (rest, Rx{Nil{}, done})

def feed.go(p: Array<U32> & U32, rx: Rx) -> Rx:
  (a, n) = p
  feed_buf(rx, a, n)

def feed.rest(p: List<&2, U32> & Rx, chunk: List<&2, U32>) -> Rx:
  (rest, rx) = p
  feed.go(B.buffer(List.append(&2, U32, rest, chunk)), rx)

# A read's bytes in, as a list: what tests and laws use.
def feed(rx: Rx, chunk: List<&2, U32>) -> Rx:
  feed.rest(rest(rx), chunk)

# The complete frames so far, oldest first, and the framer without them.
def take(rx: Rx) -> List<&2, Frame> & Rx:
  match rx:
    case Rx{rest, done}:
      (List.reverse(&2, Frame, done), Rx{rest, Nil{}})
