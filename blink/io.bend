# The IO shell: the only effectful part of Blink. It connects, then loops:
# receive bytes, hand them to the pure connection (session.bend), send what
# it asks for, and, when a query's deadline passes, sends the session's
# CancelRequest on a second connection. It decides nothing about the protocol.
import Base
import ./bytes.bend as B
import ./crypto.bend as C
import ./session.bend as S

def Replies() -> Type:
  List<&2, S.Reply>

def Next() -> Type:
  Socket -> S.Conn -> IO(Replies())

def done(s: Socket, c: S.Conn) -> IO(Replies()):
  do IO<Replies()>:
    Socket.close(s)
    return S.replies(c)

def next(open: Bool, s: Socket, c: S.Conn, k: Next()) -> IO(Replies()):
  match open:
    case True{}:
      k(s, c)
    case False{}:
      done(s, c)

def sent(m: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, +c: S.Conn,
  k: Next()) -> IO(Replies()):
  (s, r) = m
  match r:
    case Done{u}:
      next(S.open(c), s, c, k)
    case Fail{((code, message), rest)}:
      done(s, S.closed(c, message))

def send(s: Socket, p: List<&2, U32> & S.Conn, k: Next()) -> IO(Replies()):
  (out, c) = p
  do IO<Replies()>:
    m : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send_bytes(s, out)
    sent(m, c, k)

def got(m: Socket & Result<&1, &1, U32 & String, Maybe<&1, Bytes>>, c: S.Conn,
  k: Next()) -> IO(Replies()):
  (s, r) = m
  match r:
    case Done{Some{chunk}}:
      send(s, S.take(S.receive_buf(c, chunk)), k)
    case Done{None{}}:
      done(s, S.closed(c, "the server closed the connection"))
    case Fail{(code, message)}:
      done(s, S.closed(c, message))

# CancelRequest goes on a connection of its own, which the server closes.
def interrupt.sent(m: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(Unit):
  (s, r) = m
  Socket.close(s)

def interrupt.connected(r: Result<&1, &1, U32 & String, Socket>, bytes: List<&2, U32>) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.pure(Unit, Unit{})
    case Done{s}:
      do IO<Unit>:
        m : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send_bytes(s, bytes)
        interrupt.sent(m)

def interrupt(host: String, port: U32, bytes: List<&2, U32>) -> IO(Unit):
  match bytes:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case b <> rest:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, Socket> <- TCP.connect(host, port)
        interrupt.connected(r, b <> rest)

def cancelled(host: String, port: U32, s: Socket, p: List<&2, U32> & S.Conn, k: Next()) -> IO(Replies()):
  (bytes, c) = p
  do IO<Replies()>:
    interrupt(host, port, bytes)
    send(s, S.take(c), k)

def polled(host: String, port: U32,
  m: Socket & Poll<&1, &1, Result<&1, &1, U32 & String, Maybe<&1, Bytes>>, Unit>,
  c: S.Conn, k: Next()) -> IO(Replies()):
  (s, p) = m
  match p:
    case Ready{r}:
      got((s, r), c, k)
    case Wait{u}:
      cancelled(host, port, s, S.cancel(c), k)

# A read, bounded by the running query's deadline if it has one.
def read(+ms: U32, host: String, port: U32, s: Socket, c: S.Conn, k: Next()) -> IO(Replies()):
  match ms:
    case 0:
      do IO<Replies()>:
        m : Socket & Result<&1, &1, U32 & String, Maybe<&1, Bytes>> <- TCP.recv_buf(s, 65528)
        got(m, c, k)
    case _:
      do IO<Replies()>:
        m : Socket & Poll<&1, &1, Result<&1, &1, U32 & String, Maybe<&1, Bytes>>, Unit> <- TCP.try_recv_buf(s, 65528, ms)
        polled(host, port, m, c, k)

# One read per turn; the fuel only satisfies the termination check.
def loop(fuel: Nat, +host: String, +port: U32, s: Socket, +c: S.Conn) -> IO(Replies()):
  match fuel:
    case 0n:
      done(s, S.closed(c, "out of fuel"))
    case 1n+f:
      read(S.deadline(c), host, port, s, c, s2 => c2 => loop(f, host, port, s2, c2))

def connected(r: Result<&1, &1, U32 & String, Socket>, host: String, port: U32, c: S.Conn) -> IO(Replies()):
  match r:
    case Fail{(code, message)}:
      IO.pure(Replies(), [S.Reply.Closed{"connect failed: " ++ message}])
    case Done{s}:
      send(s, S.take(c), s2 => c2 => loop(4294967295n, host, port, s2, c2))

# n random words as bytes, for SCRAM's nonce.
def random(n: Nat, acc: List<&2, U32>) -> IO(List<&2, U32>):
  match n:
    case 0n:
      IO.pure(List<&2, U32>, acc)
    case 1n+p:
      do IO<List<&2, U32>>:
        x : U32 <- IO.try(U32, IO.random_u32())
        random(p, List.append(&2, U32, B.be32(x), acc))

# Connects to host (an IPv4 address) and port as user with password (which
# trust ignores), runs each query in turn (see S.Query), and answers every
# reply in order. A connection problem ends the list with Reply.Closed, and
# a failed login with an Error.
def run(+host: String, +port: U32, user: String, password: String, database: String,
  queries: List<&2, S.Query>) -> IO(Replies()):
  do IO<Replies()>:
    bytes : List<&2, U32> <- random(5n, Nil{})
    r : Result<&1, &1, U32 & String, Socket> <- TCP.connect(host, port)
    connected(r, host, port, S.connect(user, password, database,
      C.base64(List.take(&2, U32, bytes, 18n)), queries))
