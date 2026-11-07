# The session: Clunk's protocol state machine as a pure function. Backend
# messages go in; bytes to send and replies for the caller come out. It runs
# a queue of simple queries, one at a time, then says goodbye. The IO shell
# (io.bend) only moves bytes between the socket and this.
import Base
import ./frame.bend as F
import ./wire.bend as W
import ./auth.bend as A
import ./rows.bend as R

# What a caller sees, in order: the replies to its queries.
type Reply is Data:
  Reply.Columns{fields: List<&2, W.Field>}
  Reply.Row{entries: List<&2, R.Entry>}
  Reply.Complete{tag: String}
  Reply.Error{severity: String, code: String, message: String}
  Reply.Notice{severity: String, code: String, message: String}
  Reply.Closed{reason: String}

# phase 0 is startup, 1 a query running, 2 done (Terminate sent), 3 failed.
# login is where authentication stands; fields are the running statement's
# columns. out is what the shell hasn't
# sent yet; replies are every reply so far, newest-first.
type Session is Data:
  Session{phase: U32, login: A.Login, queue: List<&2, String>, fields: List<&2, W.Field>,
    out: List<&2, U32>, replies: List<&2, Reply>}

# The server is ready: send the next query, or say goodbye.
def ready(+phase: U32, login: A.Login, queue: List<&2, String>, fields: List<&2, W.Field>,
  out: List<&2, U32>, replies: List<&2, Reply>) -> Session:
  match phase:
    case 3:
      Session{3, login, queue, fields, out, replies}
    case _:
      match queue:
        case Nil{}:
          Session{2, login, Nil{}, fields, List.append(&2, U32, out, W.terminate()), replies}
        case sql <> rest:
          Session{1, login, rest, Nil{}, List.append(&2, U32, out, W.query(sql)), replies}

# An error during startup ends the session; during a query it ends only
# that query, and the server is ready again after it.
def error(+phase: U32, login: A.Login, queue: List<&2, String>, fields: List<&2, W.Field>,
  out: List<&2, U32>, replies: List<&2, Reply>, r: Reply) -> Session:
  match phase:
    case 0:
      Session{3, login, queue, fields, out, r <> replies}
    case _:
      Session{phase, login, queue, fields, out, r <> replies}

# An authentication request: send auth.bend's answer, or fail the session.
def auth(a: A.Answer, queue: List<&2, String>, fields: List<&2, W.Field>,
  out: List<&2, U32>, replies: List<&2, Reply>) -> Session:
  match a:
    case A.Answer.Send{login, bytes}:
      Session{0, login, queue, fields, List.append(&2, U32, out, bytes), replies}
    case A.Answer.Fail{message}:
      Session{3, A.Login.Done{}, queue, fields, out, Reply.Error{"FATAL", "28000", message} <> replies}

def react.go(s: Session, msg: W.Backend) -> Session:
  match s:
    case Session{+phase, login, queue, +fields, out, replies}:
      match msg:
        case W.Backend.Auth{code, data}:
          auth(A.answer(code, data, login), queue, fields, out, replies)
        case W.Backend.Ready{status}:
          ready(phase, login, queue, fields, out, replies)
        case W.Backend.Columns{+fs}:
          Session{phase, login, queue, fs, out, Reply.Columns{fs} <> replies}
        case W.Backend.Row{cells}:
          Session{phase, login, queue, fields, out, Reply.Row{R.record(fields, cells)} <> replies}
        case W.Backend.Complete{tag}:
          Session{phase, login, queue, fields, out, Reply.Complete{tag} <> replies}
        case W.Backend.Error{severity, code, message}:
          error(phase, login, queue, fields, out, replies, Reply.Error{severity, code, message})
        case W.Backend.Notice{severity, code, message}:
          Session{phase, login, queue, fields, out, Reply.Notice{severity, code, message} <> replies}
        case _:
          Session{phase, login, queue, fields, out, replies}

def failed(s: Session) -> Bool:
  match s:
    case Session{phase, login, queue, fields, out, replies}:
      U32.is_eq(phase, 3)

def react.unless(failed: Bool, s: Session, msg: W.Backend) -> Session:
  match failed:
    case True{}:
      s
    case False{}:
      react.go(s, msg)

# One backend message in. A failed session takes no more: whatever the
# server sends after a failed login, such as its own AuthenticationOk and
# ReadyForQuery, must not start a query.
def react(+s: Session, msg: W.Backend) -> Session:
  react.unless(failed(s), s, msg)

# Frames in, each decoded to its message.
def react_frames(s: Session, frames: List<&2, F.Frame>) -> Session:
  List.foldl(~&2, ~F.Frame, ~Session, ~(a => f => react(a, W.decode(f))), frames, s)

# A connection's whole pure state: the framer and the session.
type Conn is Data:
  Conn{rx: F.Rx, se: Session}

# A new connection, whose first bytes to send are the startup message.
# nonce is SCRAM's: printable random bytes, from the caller since this is pure.
def connect(+user: String, password: String, database: String, nonce: List<&2, U32>,
  queue: List<&2, String>) -> Conn:
  Conn{F.new(), Session{0, A.Login.Start{user, password, nonce}, queue, Nil{},
    W.startup(user, database), Nil{}}}

def receive.go(p: List<&2, F.Frame> & F.Rx, se: Session) -> Conn:
  (frames, rx) = p
  Conn{rx, react_frames(se, frames)}

# One read's bytes in.
def receive(c: Conn, chunk: List<&2, U32>) -> Conn:
  match c:
    case Conn{rx, se}:
      receive.go(F.take(F.feed(rx, chunk)), se)

# The bytes to send, and the connection without them.
def take(c: Conn) -> List<&2, U32> & Conn:
  match c:
    case Conn{rx, Session{phase, login, queue, fields, out, replies}}:
      (out, Conn{rx, Session{phase, login, queue, fields, Nil{}, replies}})

# Every reply so far, oldest first.
def replies(c: Conn) -> List<&2, Reply>:
  match c:
    case Conn{rx, Session{phase, login, queue, fields, out, rs}}:
      List.reverse(&2, Reply, rs)

# The socket failed or closed under the session.
def closed(c: Conn, reason: String) -> Conn:
  match c:
    case Conn{rx, Session{phase, login, queue, fields, out, rs}}:
      Conn{rx, Session{3, login, queue, fields, out, Reply.Closed{reason} <> rs}}

# Whether the session still wants the socket.
def open(c: Conn) -> Bool:
  match c:
    case Conn{rx, Session{phase, login, queue, fields, out, replies}}:
      U32.is_lt(phase, 2)

# ---- showing replies, one line each

def show.fields(fs: List<&2, W.Field>) -> String:
  match fs:
    case Nil{}:
      ""
    case W.Field{name, oid} <> rest:
      " " ++ name ++ ":" ++ U32.show(oid) ++ show.fields(rest)

def show(e: Reply) -> String:
  match e:
    case Reply.Columns{fs}:
      "columns" ++ show.fields(fs)
    case Reply.Row{es}:
      "row " ++ R.show(es)
    case Reply.Complete{tag}:
      "complete " ++ tag
    case Reply.Error{severity, code, message}:
      "error " ++ severity ++ " " ++ code ++ " " ++ message
    case Reply.Notice{severity, code, message}:
      "notice " ++ severity ++ " " ++ code ++ " " ++ message
    case Reply.Closed{reason}:
      "closed " ++ reason
