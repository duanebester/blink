# The session: Clunk's protocol state machine as a pure function. Backend
# messages go in; bytes to send and replies for the caller come out. It runs
# a queue of simple queries, one at a time, then says goodbye. The IO shell
# (io.bend) only moves bytes between the socket and this.
import Base
import ./frame.bend as F
import ./wire.bend as W
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
# fields are the running statement's columns. out is what the shell hasn't
# sent yet; replies are every reply so far, newest-first.
type Session is Data:
  Session{phase: U32, queue: List<&2, String>, fields: List<&2, W.Field>,
    out: List<&2, U32>, replies: List<&2, Reply>}

# The server is ready: send the next query, or say goodbye.
def ready(+phase: U32, queue: List<&2, String>, fields: List<&2, W.Field>,
  out: List<&2, U32>, replies: List<&2, Reply>) -> Session:
  match phase:
    case 3:
      Session{3, queue, fields, out, replies}
    case _:
      match queue:
        case Nil{}:
          Session{2, Nil{}, fields, List.append(&2, U32, out, W.terminate()), replies}
        case sql <> rest:
          Session{1, rest, Nil{}, List.append(&2, U32, out, W.query(sql)), replies}

# An error during startup ends the session; during a query it ends only
# that query, and the server is ready again after it.
def error(+phase: U32, queue: List<&2, String>, fields: List<&2, W.Field>,
  out: List<&2, U32>, replies: List<&2, Reply>, r: Reply) -> Session:
  match phase:
    case 0:
      Session{3, queue, fields, out, r <> replies}
    case _:
      Session{phase, queue, fields, out, r <> replies}

# Only trust (AuthenticationOk, 0) for now.
def auth(+code: U32, queue: List<&2, String>, fields: List<&2, W.Field>,
  out: List<&2, U32>, replies: List<&2, Reply>) -> Session:
  match code:
    case 0:
      Session{0, queue, fields, out, replies}
    case _:
      Session{3, queue, fields, out, Reply.Error{"FATAL", "28000",
        "authentication request " ++ U32.show(code) ++ " is not supported yet; Blink supports trust only"}
        <> replies}

# One backend message in.
def react(s: Session, msg: W.Backend) -> Session:
  match s:
    case Session{+phase, queue, +fields, out, replies}:
      match msg:
        case W.Backend.Auth{code}:
          auth(code, queue, fields, out, replies)
        case W.Backend.Ready{status}:
          ready(phase, queue, fields, out, replies)
        case W.Backend.Columns{+fs}:
          Session{phase, queue, fs, out, Reply.Columns{fs} <> replies}
        case W.Backend.Row{cells}:
          Session{phase, queue, fields, out, Reply.Row{R.record(fields, cells)} <> replies}
        case W.Backend.Complete{tag}:
          Session{phase, queue, fields, out, Reply.Complete{tag} <> replies}
        case W.Backend.Error{severity, code, message}:
          error(phase, queue, fields, out, replies, Reply.Error{severity, code, message})
        case W.Backend.Notice{severity, code, message}:
          Session{phase, queue, fields, out, Reply.Notice{severity, code, message} <> replies}
        case _:
          Session{phase, queue, fields, out, replies}

# Frames in, each decoded to its message.
def react_frames(s: Session, frames: List<&2, F.Frame>) -> Session:
  List.foldl(~&2, ~F.Frame, ~Session, ~(a => f => react(a, W.decode(f))), frames, s)

# A connection's whole pure state: the framer and the session.
type Conn is Data:
  Conn{rx: F.Rx, se: Session}

# A new connection, whose first bytes to send are the startup message.
def connect(user: String, database: String, queue: List<&2, String>) -> Conn:
  Conn{F.new(), Session{0, queue, Nil{}, W.startup(user, database), Nil{}}}

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
    case Conn{rx, Session{phase, queue, fields, out, replies}}:
      (out, Conn{rx, Session{phase, queue, fields, Nil{}, replies}})

# Every reply so far, oldest first.
def replies(c: Conn) -> List<&2, Reply>:
  match c:
    case Conn{rx, Session{phase, queue, fields, out, rs}}:
      List.reverse(&2, Reply, rs)

# The socket failed or closed under the session.
def closed(c: Conn, reason: String) -> Conn:
  match c:
    case Conn{rx, Session{phase, queue, fields, out, rs}}:
      Conn{rx, Session{3, queue, fields, out, Reply.Closed{reason} <> rs}}

# Whether the session still wants the socket.
def open(c: Conn) -> Bool:
  match c:
    case Conn{rx, Session{phase, queue, fields, out, replies}}:
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
