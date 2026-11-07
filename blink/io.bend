# The IO shell: the only effectful part of Blink. It connects, then loops:
# receive bytes, hand them to the pure connection (session.bend), send what
# it asks for. It decides nothing about the protocol.
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

def got(m: Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>, c: S.Conn,
  k: Next()) -> IO(Replies()):
  (s, r) = m
  match r:
    case Done{Some{chunk}}:
      send(s, S.take(S.receive(c, chunk)), k)
    case Done{None{}}:
      done(s, S.closed(c, "the server closed the connection"))
    case Fail{(code, message)}:
      done(s, S.closed(c, message))

# One read per turn; the fuel only satisfies the termination check.
def loop(fuel: Nat, s: Socket, c: S.Conn) -> IO(Replies()):
  match fuel:
    case 0n:
      done(s, S.closed(c, "out of fuel"))
    case 1n+f:
      do IO<Replies()>:
        m : Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>> <- TCP.recv_bytes(s, 65536)
        got(m, c, s2 => c2 => loop(f, s2, c2))

def connected(r: Result<&1, &1, U32 & String, Socket>, c: S.Conn) -> IO(Replies()):
  match r:
    case Fail{(code, message)}:
      IO.pure(Replies(), [S.Reply.Closed{"connect failed: " ++ message}])
    case Done{s}:
      send(s, S.take(c), s2 => c2 => loop(4294967295n, s2, c2))

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
# trust ignores), runs each query in turn with the simple query protocol,
# and answers every reply in order. A connection problem ends the list with
# Reply.Closed, and a failed login with an Error.
def run(host: String, port: U32, user: String, password: String, database: String,
  queries: List<&2, String>) -> IO(Replies()):
  do IO<Replies()>:
    bytes : List<&2, U32> <- random(5n, Nil{})
    r : Result<&1, &1, U32 & String, Socket> <- TCP.connect(host, port)
    connected(r, S.connect(user, password, database,
      C.base64(List.take(&2, U32, bytes, 18n)), queries))
