# Framing: bytes -> frames. TCP delivers a stream, not messages: one read
# may hold several messages, the end of one, or part of a header. The
# framer is a fold over bytes with its state carried between reads, so how
# the stream was cut never matters (LAWS.bend: feed_split, for every
# stream and every cut). A DataRow is cut into its cells as its bytes go
# by, so a row's bytes are walked once. Pure.
import Base

# A backend message: its tag byte and its body, without the length. A
# DataRow comes already cut into its cells (None is NULL).
type Frame is Data:
  Frame{tag: U32, body: List<&2, U32>}
  Frame.Row{cells: List<&2, Maybe<&2, List<&2, U32>>>}

# phase 0 waits for a tag; 1 to 4 read the length into w; 5 reads a body
# into cur. A DataRow instead goes 6-7 (its cell count, unused: the length
# says where it ends), 8-11 (a cell's length into w), 12 (a cell's bytes,
# left to go, into cur). need is the message's bytes still to come. cur,
# cells and done are newest-first.
type Rx is Data:
  Rx{phase: U32, tag: U32, need: U32, w: U32, left: U32, cur: List<&2, U32>,
    cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>}

def new() -> Rx:
  Rx{0, 0, 0, 0, 0, Nil{}, Nil{}, Nil{}}

def ready(f: Frame, done: List<&2, Frame>) -> Rx:
  Rx{0, 0, 0, 0, 0, Nil{}, Nil{}, f <> done}

# ---- a body

def body(last: Bool, tag: U32, need: U32, cur: List<&2, U32>, done: List<&2, Frame>) -> Rx:
  match last:
    case True{}:
      ready(Frame{tag, List.reverse(&2, U32, cur)}, done)
    case False{}:
      Rx{5, tag, need, 0, 0, cur, Nil{}, done}

# ---- a DataRow's cells

# The row's state after a byte; its last byte hands the row over.
def row(last: Bool, phase: U32, need: U32, w: U32, left: U32, cur: List<&2, U32>,
  cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>) -> Rx:
  match last:
    case True{}:
      ready(Frame.Row{List.reverse(&2, Maybe<&2, List<&2, U32>>, cells)}, done)
    case False{}:
      Rx{phase, 68, need, w, left, cur, cells, done}

# A cell's length is in: -1 is NULL, 0 an empty cell, else its bytes follow.
def cell(+len: U32, +need: U32, cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>) -> Rx:
  match len:
    case 4294967295:
      row(U32.is_eq(need, 0), 8, need, 0, 0, Nil{}, None{} <> cells, done)
    case 0:
      row(U32.is_eq(need, 0), 8, need, 0, 0, Nil{}, Some{Nil{}} <> cells, done)
    case _:
      row(U32.is_eq(need, 0), 12, need, 0, len, Nil{}, cells, done)

# A cell's byte is in.
def bytes(full: Bool, +need: U32, left: U32, cur: List<&2, U32>,
  cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>) -> Rx:
  match full:
    case True{}:
      row(U32.is_eq(need, 0), 8, need, 0, 0, Nil{}, Some{List.reverse(&2, U32, cur)} <> cells, done)
    case False{}:
      row(U32.is_eq(need, 0), 12, need, 0, left, cur, cells, done)

# ---- the header

# The length is in. It counts its own four bytes; less is malformed, read
# as 4.
def length(row: Bool, tag: U32, +need: U32, done: List<&2, Frame>) -> Rx:
  match row need:
    case True{} 0:
      ready(Frame.Row{Nil{}}, done)
    case True{} _:
      Rx{6, 68, need, 0, 0, Nil{}, Nil{}, done}
    case False{} 0:
      ready(Frame{tag, Nil{}}, done)
    case False{} _:
      Rx{5, tag, need, 0, 0, Nil{}, Nil{}, done}

# A byte of a big-endian word is in: the length (phases 1-4), the cell
# count (6) or a cell's length (8-10).
def step.word(header: Bool, +phase: U32, tag: U32, +need: U32, w: U32,
  cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>) -> Rx:
  match header:
    case True{}:
      Rx{(phase + 1 : U32), tag, 0, w, 0, Nil{}, Nil{}, done}
    case False{}:
      row(U32.is_eq(need, 1), (phase + 1 : U32), (need - 1 : U32), w, 0, Nil{}, cells, done)

# One byte in.
def step(rx: Rx, +b: U32) -> Rx:
  match rx:
    case Rx{+phase, +tag, +need, +w, +left, cur, cells, done}:
      match phase:
        case 0:
          Rx{1, b, 0, 0, 0, Nil{}, Nil{}, done}
        case 4:
          length(U32.is_eq(tag, 68), tag, (U32.max(((w << 8n) .|. b : U32), 4) - 4 : U32), done)
        case 5:
          body(U32.is_eq(need, 1), tag, (need - 1 : U32), b <> cur, done)
        case 7:
          row(U32.is_eq(need, 1), 8, (need - 1 : U32), 0, 0, Nil{}, cells, done)
        case 11:
          cell(((w << 8n) .|. b : U32), (need - 1 : U32), cells, done)
        case 12:
          bytes(U32.is_eq(left, 1), (need - 1 : U32), (left - 1 : U32), b <> cur, cells, done)
        case _:
          step.word(U32.is_lt(phase, 5), phase, tag, need, ((w << 8n) .|. b : U32), cells, done)
# A read's bytes in.
def feed(rx: Rx, chunk: List<&2, U32>) -> Rx:
  List.foldl(~&2, ~U32, ~Rx, ~(s => b => step(s, b)), chunk, rx)

# The complete frames so far, oldest first, and the framer without them.
def take(rx: Rx) -> List<&2, Frame> & Rx:
  match rx:
    case Rx{phase, tag, need, w, left, cur, cells, done}:
      (List.reverse(&2, Frame, done), Rx{phase, tag, need, w, left, cur, cells, Nil{}})
