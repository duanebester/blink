# The IO shell: the only effectful part of Blink. It connects, then loops:
# receive bytes, run them through frame -> wire -> session (all pure), send
# what the session asks for. It decides nothing about the protocol.
import Base
import ./frame.bend as F
import ./session.bend as S

def Replies() -> Type:
  List<&2, S.Reply>

# replies arrive oldest-first; acc keeps them newest-first
def keep(acc: Replies(), replies: Replies()) -> Replies():
  List.foldl(~&2, ~S.Reply, ~Replies(), ~(a => r => r <> a), replies, acc)

def finish(acc: Replies()) -> IO(Replies()):
  IO.pure(Replies(), List.reverse(&2, S.Reply, acc))

def closed(s: Socket, acc: Replies(), reason: String) -> IO(Replies()):
  do IO<Replies()>:
    Socket.close(s)
    finish(S.Reply.Closed{reason} <> acc)

def Next() -> Type:
  Socket -> F.Rx -> S.Session -> Replies() -> IO(Replies())

def next(open: Bool, s: Socket, rx: F.Rx, se: S.Session, acc: Replies(), k: Next()) -> IO(Replies()):
  match open:
    case True{}:
      k(s, rx, se, acc)
    case False{}:
      do IO<Replies()>:
        Socket.close(s)
        finish(acc)

def sent(m: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, rx: F.Rx,
  +se: S.Session, acc: Replies(), k: Next()) -> IO(Replies()):
  (s, r) = m
  match r:
    case Done{u}:
      next(S.open(se), s, rx, se, acc, k)
    case Fail{((code, message), rest)}:
      closed(s, acc, message)

def reacted(s: Socket, rx: F.Rx, q: (List<&2, U32> & Replies()) & S.Session, acc: Replies(),
  k: Next()) -> IO(Replies()):
  ((out, replies), se) = q
  do IO<Replies()>:
    m : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send_bytes(s, out)
    sent(m, rx, se, keep(acc, replies), k)

def framed(s: Socket, p: List<&2, F.Frame> & F.Rx, se: S.Session, acc: Replies(), k: Next()) ->
  IO(Replies()):
  (frames, rx) = p
  reacted(s, rx, S.take(S.react_frames(se, frames)),
    acc, k)

def got(m: Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>, rx: F.Rx,
  se: S.Session, acc: Replies(), k: Next()) -> IO(Replies()):
  (s, r) = m
  match r:
    case Done{Some{chunk}}:
      framed(s, F.take(F.feed(rx, chunk)), se, acc, k)
    case Done{None{}}:
      closed(s, acc, "the server closed the connection")
    case Fail{(code, message)}:
      closed(s, acc, message)

# One read per turn; the fuel only satisfies the termination check.
def loop(fuel: Nat, s: Socket, rx: F.Rx, se: S.Session, acc: Replies()) -> IO(Replies()):
  match fuel:
    case 0n:
      closed(s, acc, "out of fuel")
    case 1n+f:
      do IO<Replies()>:
        m : Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>> <- TCP.recv_bytes(s, 65536)
        got(m, rx, se, acc, s2 => rx2 => se2 => acc2 => loop(f, s2, rx2, se2, acc2))

def started(m: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>,
  queries: List<&2, String>) -> IO(Replies()):
  (s, r) = m
  match r:
    case Done{u}:
      loop(4294967295n, s, F.new(), S.new(queries), Nil{})
    case Fail{((code, message), rest)}:
      closed(s, Nil{}, message)

def connected(r: Result<&1, &1, U32 & String, Socket>, user: String, database: String,
  queries: List<&2, String>) -> IO(Replies()):
  match r:
    case Fail{(code, message)}:
      IO.pure(Replies(), [S.Reply.Closed{"connect failed: " ++ message}])
    case Done{s}:
      do IO<Replies()>:
        m : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send_bytes(s, S.hello(user, database))
        started(m, queries)

# Connects to host (an IPv4 address) and port as user, runs each query in
# turn with the simple query protocol, and answers every reply in order.
# A connection problem ends the list with Reply.Closed.
def run(host: String, port: U32, user: String, database: String, queries: List<&2, String>) ->
  IO(Replies()):
  do IO<Replies()>:
    r : Result<&1, &1, U32 & String, Socket> <- TCP.connect(host, port)
    connected(r, user, database, queries)
