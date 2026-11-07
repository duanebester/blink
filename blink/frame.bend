# Framing: bytes -> frames. TCP delivers a stream, not messages: one read
# may hold several messages, the end of one, or part of a header. The
# framer is a fold over bytes with its state carried between reads, so how
# the stream was cut never matters (LAWS.bend: feed_split). Pure.
import Base

# A backend message: its tag byte and its body, without the length.
type Frame is Data:
  Frame{tag: U32, body: List<&2, U32>}

# phase 0 waits for a tag, 1 to 4 read the length, 5 reads the body with
# need bytes left. body and done are newest-first.
type Rx is Data:
  Rx{phase: U32, tag: U32, need: U32, body: List<&2, U32>, done: List<&2, Frame>}

def new() -> Rx:
  Rx{0, 0, 0, Nil{}, Nil{}}

def emit(full: Bool, +tag: U32, need: U32, body: List<&2, U32>, done: List<&2, Frame>) -> Rx:
  match full:
    case True{}:
      Rx{0, 0, 0, Nil{}, Frame{tag, List.reverse(&2, U32, body)} <> done}
    case False{}:
      Rx{5, tag, need, body, done}

# The length counts its own four bytes, so 4 is an empty body.
def length(last: Bool, +phase: U32, tag: U32, +n: U32, done: List<&2, Frame>) -> Rx:
  match last:
    case True{}:
      emit(U32.is_eq(n, 4), tag, (n - 4 : U32), Nil{}, done)
    case False{}:
      Rx{(phase + 1 : U32), tag, n, Nil{}, done}

def step.go(start: Bool, in_body: Bool, +phase: U32, tag: U32, +need: U32,
  body: List<&2, U32>, done: List<&2, Frame>, +b: U32) -> Rx:
  match start in_body:
    case True{} _:
      Rx{1, b, 0, Nil{}, done}
    case False{} True{}:
      emit(U32.is_eq(need, 1), tag, (need - 1 : U32), b <> body, done)
    case False{} False{}:
      length(U32.is_eq(phase, 4), phase, tag, (need * 256 + b : U32), done)

# One byte in.
def step(rx: Rx, +b: U32) -> Rx:
  match rx:
    case Rx{+phase, tag, need, body, done}:
      step.go(U32.is_eq(phase, 0), U32.is_eq(phase, 5), phase, tag, need, body, done, b)

# A read's bytes in.
def feed(rx: Rx, chunk: List<&2, U32>) -> Rx:
  List.foldl(~&2, ~U32, ~Rx, ~(s => b => step(s, b)), chunk, rx)

# The complete frames so far, oldest first, and the framer without them.
def take(rx: Rx) -> List<&2, Frame> & Rx:
  match rx:
    case Rx{phase, tag, need, body, done}:
      (List.reverse(&2, Frame, done), Rx{phase, tag, need, body, Nil{}})
