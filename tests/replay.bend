# Replays a recorded session (tests/fixtures, from capture.py) through the
# pure pipeline, bytes -> frames -> messages -> session, with no socket and
# no server: the server's bytes go in 7 at a time, so messages and headers
# split across reads. Prints each reply, then whether the session answered
# with exactly the bytes the recorded client sent. Run from the repo root;
# tests/replay.expected is what it must print.
import Base
import ../blink/bytes.bend as B
import ../blink/session.bend as S

type Replay is Data:
  Replay{c: S.Conn, out: List<&2, U32>}

def chunk.go(p: List<&2, U32> & S.Conn, out: List<&2, U32>) -> Replay:
  (o, c) = p
  Replay{c, List.append(&2, U32, out, o)}

def chunk(r: Replay, bytes: List<&2, U32>) -> Replay:
  match r:
    case Replay{c, out}:
      chunk.go(S.take(S.receive(c, bytes)), out)

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
  go(List.length(&2, U32, server), Replay{S.connect("trusty", "", "world", Nil{}, ["SELECT 1::int4 AS one, 'héllo'::text AS t, NULL::text AS n, true AS b, -42 AS neg; SELECT 1/0", "SELECT 'after' AS a"]), Nil{}},
    B.split(server, 7n))

def report(r: Replay, client: List<&2, U32>) -> IO(Unit):
  match r:
    case Replay{c, out}:
      do IO<Unit>:
        List.for_each(~&2, ~S.Reply, ~(r => IO.print(S.show(r))), S.replies(c))
        IO.print(Bool.pick(String, B.eq(out, client), "client bytes match", "client bytes differ"))

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
