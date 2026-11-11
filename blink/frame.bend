# Framing: bytes -> frames. TCP delivers a stream, not messages: one read
# may hold several messages, the end of one, or part of a header. A read
# arrives as Base's Bytes (bendlang/bend#1573): compiled, one shared block.
# The framer reads each 5-byte header, cuts the whole messages, and keeps
# the bytes after the last one, a slice, which the next read is joined to
# (a copy only when something is left), so how the stream was cut never
# matters (LAWS.bend: feed_split, for every stream and every cut). A
# DataRow's cells are slices of the read: no cell byte is copied. Pure.
import Base

# A backend message: its tag byte and its body, without the length. A
# DataRow comes already cut into its cells (None is NULL), each a slice of
# the read it came in.
type Frame is Data:
  Frame{tag: U32, body: List<&2, U32>}
  Frame.Row{cells: List<&2, Maybe<&2, Bytes>>}

# rest is the bytes after the last whole message; done is newest-first.
type Rx is Data:
  Rx{rest: Bytes, done: List<&2, Frame>}

def new() -> Rx:
  Rx{Bytes.empty(), Nil{}}

# ---- a DataRow's cells: a count, then each cell's length (-1 is NULL)
# and bytes, all within its body

type Cells is Data:
  Cells{at: Nat, cells: List<&2, Maybe<&2, Bytes>>}

def cell(null: Bool, +body: Bytes, +i: Nat, +len: U32, cs: List<&2, Maybe<&2, Bytes>>) -> Cells:
  match null:
    case True{}:
      Cells{4n+i, None{} <> cs}
    case False{}:
      +n = U32.to_nat(len)
      Cells{Nat.add(4n+i, n), Some{Bytes.slice(body, 4n+i, n)} <> cs}

# j cells from c's position, newest-first.
def cells(j: Nat, +body: Bytes, c: Cells) -> Cells:
  match j:
    case 0n:
      c
    case 1n+q:
      match c:
        case Cells{+i, cs}:
          +len = Bytes.be32(body, i)
          cells(q, body, cell(U32.is_eq(len, 4294967295), body, i, len, cs))

def row.got(c: Cells) -> Frame:
  match c:
    case Cells{i, cs}:
      Frame.Row{List.reverse(&2, Maybe<&2, Bytes>, cs)}

def row(+body: Bytes) -> Frame:
  row.got(cells(U32.to_nat(Bytes.be16(body, 0n)), body, Cells{2n, Nil{}}))

# ---- whole messages

# A whole message from its tag and body: what it says depends on them
# alone.
def message(is_row: Bool, tag: U32, body: Bytes) -> Frame:
  match is_row:
    case True{}:
      row(body)
    case False{}:
      Frame{tag, Bytes.to_list(body)}

# What the bytes start with: a whole message and how many bytes it takes,
# or not enough bytes for one.
type Step is Data:
  Step.Frame{frame: Frame, size: Nat}
  Step.Stop{}

def step.whole(short: Bool, +b: Bytes, +w: Nat) -> Step:
  match short:
    case True{}:
      Step.Stop{}
    case False{}:
      +tag = Bytes.get(b, 0n)
      Step.Frame{message(U32.is_eq(tag, 68), tag, Bytes.slice(b, 5n, w)), 5n+w}

# A message is its tag, its length's four bytes, which count themselves
# (less is malformed, read as 4), and w more bytes, its body.
def step.have(long: Bool, +b: Bytes) -> Step:
  match long:
    case False{}:
      Step.Stop{}
    case True{}:
      +w = Nat.sub(U32.to_nat(Bytes.be32(b, 1n)), 4n)
      step.whole(Nat.is_lt(Bytes.length(b), 5n+w), b, w)

# A header is 5 bytes: 4 < the length.
def step(+b: Bytes) -> Step:
  step.have(Nat.is_lt(4n, Bytes.length(b)), b)

# Cuts whole messages off the front of b until too few bytes are left,
# which stay for the next read. Each message is at least 5 bytes, so j,
# b's length, is more steps than needed.
def cut.go(j: Nat, b: Bytes, st: Step, done: List<&2, Frame>) -> Rx:
  match j st:
    case _ Step.Stop{}:
      Rx{b, done}
    case 0n Step.Frame{f, size}:
      Rx{b, done}
    case 1n+q Step.Frame{f, size}:
      +rest = Bytes.drop(b, size)
      cut.go(q, rest, step(rest), f <> done)

def cut(+b: Bytes, done: List<&2, Frame>) -> Rx:
  cut.go(Bytes.length(b), b, step(b), done)

# A read's bytes in, after the bytes left from the last (concat costs
# nothing when none are left).
def feed_bytes(rx: Rx, chunk: Bytes) -> Rx:
  match rx:
    case Rx{rest, done}:
      cut(Bytes.concat(rest, chunk), done)

# A read's bytes in, as a list: what tests and laws use.
def feed(rx: Rx, chunk: List<&2, U32>) -> Rx:
  feed_bytes(rx, Bytes.of_list(chunk))

# The complete frames so far, oldest first, and the framer without them.
def take(rx: Rx) -> List<&2, Frame> & Rx:
  match rx:
    case Rx{rest, done}:
      (List.reverse(&2, Frame, done), Rx{rest, Nil{}})
