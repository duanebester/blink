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

# Where the framer stands: waiting for a tag; reading the length's four
# bytes into w; reading a body into cur. A DataRow instead reads its cell
# count (unused: the length says where it ends), each cell's length into w,
# and each cell's bytes into cur. An enum, not a number, so that a proof can
# take every phase as a case.
type Phase is Data:
  Phase.Tag{}
  Phase.Len1{}
  Phase.Len2{}
  Phase.Len3{}
  Phase.Len4{}
  Phase.Body{}
  Phase.Count1{}
  Phase.Count2{}
  Phase.Size1{}
  Phase.Size2{}
  Phase.Size3{}
  Phase.Size4{}
  Phase.Cell{}

# need is the message's bytes still to come; left, a cell's. cur, cells and
# done are newest-first.
type Rx is Data:
  Rx{phase: Phase, tag: U32, need: U32, w: U32, left: U32, cur: List<&2, U32>,
    cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>}

def new() -> Rx:
  Rx{Phase.Tag{}, 0, 0, 0, 0, Nil{}, Nil{}, Nil{}}

def ready(f: Frame, done: List<&2, Frame>) -> Rx:
  Rx{Phase.Tag{}, 0, 0, 0, 0, Nil{}, Nil{}, f <> done}

# ---- a body

def body(last: Bool, tag: U32, need: U32, cur: List<&2, U32>, done: List<&2, Frame>) -> Rx:
  match last:
    case True{}:
      ready(Frame{tag, List.reverse(&2, U32, cur)}, done)
    case False{}:
      Rx{Phase.Body{}, tag, need, 0, 0, cur, Nil{}, done}

# ---- a DataRow's cells

# The row's state after a byte; its last byte hands the row over.
def row(last: Bool, phase: Phase, need: U32, w: U32, left: U32, cur: List<&2, U32>,
  cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>) -> Rx:
  match last:
    case True{}:
      ready(Frame.Row{List.reverse(&2, Maybe<&2, List<&2, U32>>, cells)}, done)
    case False{}:
      Rx{phase, 68, need, w, left, cur, cells, done}

# A cell's length is in: -1 is NULL, 0 an empty cell, else its bytes follow.
def cell(null: Bool, empty: Bool, len: U32, +need: U32, cells: List<&2, Maybe<&2, List<&2, U32>>>,
  done: List<&2, Frame>) -> Rx:
  match null empty:
    case True{} _:
      row(U32.is_eq(need, 0), Phase.Size1{}, need, 0, 0, Nil{}, None{} <> cells, done)
    case False{} True{}:
      row(U32.is_eq(need, 0), Phase.Size1{}, need, 0, 0, Nil{}, Some{Nil{}} <> cells, done)
    case False{} False{}:
      row(U32.is_eq(need, 0), Phase.Cell{}, need, 0, len, Nil{}, cells, done)

def cell.at(+len: U32, need: U32, cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>) -> Rx:
  cell(U32.is_eq(len, 4294967295), U32.is_eq(len, 0), len, need, cells, done)

# A cell's byte is in.
def bytes(full: Bool, +need: U32, left: U32, cur: List<&2, U32>,
  cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, Frame>) -> Rx:
  match full:
    case True{}:
      row(U32.is_eq(need, 0), Phase.Size1{}, need, 0, 0, Nil{}, Some{List.reverse(&2, U32, cur)} <> cells, done)
    case False{}:
      row(U32.is_eq(need, 0), Phase.Cell{}, need, 0, left, cur, cells, done)

# ---- the header

# The length is in. It counts its own four bytes; less is malformed, read
# as 4.
def length(row: Bool, empty: Bool, tag: U32, need: U32, done: List<&2, Frame>) -> Rx:
  match row empty:
    case True{} True{}:
      ready(Frame.Row{Nil{}}, done)
    case True{} False{}:
      Rx{Phase.Count1{}, 68, need, 0, 0, Nil{}, Nil{}, done}
    case False{} True{}:
      ready(Frame{tag, Nil{}}, done)
    case False{} False{}:
      Rx{Phase.Body{}, tag, need, 0, 0, Nil{}, Nil{}, done}

def length.at(+tag: U32, +need: U32, done: List<&2, Frame>) -> Rx:
  length(U32.is_eq(tag, 68), U32.is_eq(need, 0), tag, need, done)

# A byte of a DataRow's cell count or a cell's length is in.
def word(+need: U32, phase: Phase, w: U32, cells: List<&2, Maybe<&2, List<&2, U32>>>,
  done: List<&2, Frame>) -> Rx:
  row(U32.is_eq(need, 1), phase, (need - 1 : U32), w, 0, Nil{}, cells, done)

# One byte in.
def step(rx: Rx, +b: U32) -> Rx:
  match rx:
    case Rx{phase, +tag, +need, +w, +left, cur, cells, done}:
      match phase:
        case Phase.Tag{}:
          Rx{Phase.Len1{}, b, 0, 0, 0, Nil{}, Nil{}, done}
        case Phase.Len1{}:
          Rx{Phase.Len2{}, tag, 0, ((w << 8n) .|. b : U32), 0, Nil{}, Nil{}, done}
        case Phase.Len2{}:
          Rx{Phase.Len3{}, tag, 0, ((w << 8n) .|. b : U32), 0, Nil{}, Nil{}, done}
        case Phase.Len3{}:
          Rx{Phase.Len4{}, tag, 0, ((w << 8n) .|. b : U32), 0, Nil{}, Nil{}, done}
        case Phase.Len4{}:
          length.at(tag, (U32.max(((w << 8n) .|. b : U32), 4) - 4 : U32), done)
        case Phase.Body{}:
          body(U32.is_eq(need, 1), tag, (need - 1 : U32), b <> cur, done)
        case Phase.Count1{}:
          word(need, Phase.Count2{}, 0, cells, done)
        case Phase.Count2{}:
          word(need, Phase.Size1{}, 0, cells, done)
        case Phase.Size1{}:
          word(need, Phase.Size2{}, ((w << 8n) .|. b : U32), cells, done)
        case Phase.Size2{}:
          word(need, Phase.Size3{}, ((w << 8n) .|. b : U32), cells, done)
        case Phase.Size3{}:
          word(need, Phase.Size4{}, ((w << 8n) .|. b : U32), cells, done)
        case Phase.Size4{}:
          cell.at(((w << 8n) .|. b : U32), (need - 1 : U32), cells, done)
        case Phase.Cell{}:
          bytes(U32.is_eq(left, 1), (need - 1 : U32), (left - 1 : U32), b <> cur, cells, done)

# A read's bytes in.
def feed(rx: Rx, chunk: List<&2, U32>) -> Rx:
  List.foldl(~&2, ~U32, ~Rx, ~(s => b => step(s, b)), chunk, rx)

# The complete frames so far, oldest first, and the framer without them.
def take(rx: Rx) -> List<&2, Frame> & Rx:
  match rx:
    case Rx{phase, tag, need, w, left, cur, cells, done}:
      (List.reverse(&2, Frame, done), Rx{phase, tag, need, w, left, cur, cells, Nil{}})
