# receive_split on the recorded session, at every cut: receiving the
# server's bytes as two reads, cut at k, must give exactly the replies and
# the bytes to send of one read, for every k. PROOF.bend proves it for
# every stream; this runs it on the compiled lane too, where Bytes is the
# native shared block, not its list. Run from the repo root; it prints the
# number of cuts and whether all of them agree.
import Base
import ../blink/bytes.bend as B
import ../blink/session.bend as S
import ./replay.bend as R

def lines(rs: List<&2, S.Reply>) -> String:
  match rs:
    case Nil{}:
      ""
    case r <> rest:
      S.show(r) ++ "\n" ++ lines(rest)

# What a connection shows: its replies and the bytes it would send.
def seen(p: List<&2, U32> & S.Conn) -> String:
  (out, c) = p
  lines(S.replies(c)) ++ B.text(out)

def conn() -> S.Conn:
  S.connect("trusty", "", "world", Nil{}, R.queries())

def cut(+server: List<&2, U32>, +k: Nat) -> String:
  seen(S.take(S.receive(S.receive(conn(), List.take(&2, U32, server, k)),
    List.drop(&2, U32, server, k))))

def check(j: Nat, +server: List<&2, U32>, +whole: String, +k: Nat, +bad: Nat) -> Nat:
  match j:
    case 0n:
      bad
    case 1n+q:
      check(q, server, whole, 1n+k,
        Bool.pick(Nat, String.eq(cut(server, k), whole), bad, 1n+bad))

def main() -> IO(Unit):
  do IO<Unit>:
    +server : List<&2, U32> <- R.read("tests/fixtures/session.server.bin")
    +n : Nat = List.length(&2, U32, server)
    IO.print(Nat.show(1n+n) ++ " cuts, " ++ Nat.show(check(1n+n, server,
      seen(S.take(S.receive(conn(), server))), 0n, 0n)) ++ " differ")
