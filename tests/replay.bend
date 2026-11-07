# Replays a recorded session (tests/fixtures, from capture.py) through the
# pure pipeline, bytes -> frames -> messages -> session, with no socket and
# no server: the server's bytes go in 7 at a time, so messages and headers
# split across reads. Prints each reply, then whether the session answered
# with exactly the bytes the recorded client sent. Run from the repo root;
# tests/replay.expected is what it must print.
import Base
import ../blink/bytes.bend as B
import ../blink/frame.bend as F
import ../blink/session.bend as S

# replies newest-first
type Replay is Data:
  Replay{rx: F.Rx, se: S.Session, out: List<&2, U32>, replies: List<&2, S.Reply>}

def keep(acc: List<&2, S.Reply>, rs: List<&2, S.Reply>) -> List<&2, S.Reply>:
  List.foldl(~&2, ~S.Reply, ~List<&2, S.Reply>, ~(a => r => r <> a), rs, acc)

def taken(rx: F.Rx, q: (List<&2, U32> & List<&2, S.Reply>) & S.Session, out: List<&2, U32>,
  replies: List<&2, S.Reply>) -> Replay:
  ((o, rs), se) = q
  Replay{rx, se, List.append(&2, U32, out, o), keep(replies, rs)}

def framed(p: List<&2, F.Frame> & F.Rx, se: S.Session, out: List<&2, U32>,
  replies: List<&2, S.Reply>) -> Replay:
  (frames, rx) = p
  taken(rx, S.take(S.react_frames(se, frames)), out, replies)

def chunk(r: Replay, bytes: List<&2, U32>) -> Replay:
  match r:
    case Replay{rx, se, out, replies}:
      framed(F.take(F.feed(rx, bytes)), se, out, replies)

def go(fuel: Nat, r: Replay, c: B.Cut) -> Replay:
  match fuel:
    case 0n:
      r
    case 1n+f:
      match c:
        case B.Cut{bytes, rest}:
          match rest:
            case Nil{}:
              chunk(r, bytes)
            case h <> t:
              go(f, chunk(r, bytes), B.split(h <> t, 7n))

def replay(+server: List<&2, U32>) -> Replay:
  go(List.length(&2, U32, server), Replay{F.new(), S.new(["SELECT 1::int4 AS one, 'héllo'::text AS t, NULL::text AS n, true AS b, -42 AS neg; SELECT 1/0", "SELECT 'after' AS a"]), Nil{}, Nil{}},
    B.split(server, 7n))

def eq(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  match a b:
    case Nil{} Nil{}:
      True{}
    case x <> xs y <> ys:
      Bool.and(U32.is_eq(x, y), eq(xs, ys))
    case _ _:
      False{}

def prints(rs: List<&2, S.Reply>) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case r <> rest:
      do IO<Unit>:
        IO.print(S.show(r))
        prints(rest)

def report(r: Replay, client: List<&2, U32>) -> IO(Unit):
  match r:
    case Replay{rx, se, out, replies}:
      do IO<Unit>:
        prints(List.reverse(&2, S.Reply, replies))
        IO.print(Bool.pick(String, eq(out, client), "client bytes match", "client bytes differ"))

def read.got(m: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(List<&2, U32>):
  (f, r) = m
  do IO<List<&2, U32>>:
    File.close(f)
    IO.pass(List<&2, U32>, r)

def read(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    f : File <- IO.try(File, File.open(path, "r"))
    m : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 1048576)
    read.got(m)

def main() -> IO(Unit):
  do IO<Unit>:
    server : List<&2, U32> <- read("tests/fixtures/session.server.bin")
    client : List<&2, U32> <- read("tests/fixtures/session.client.bin")
    report(replay(server), client)
