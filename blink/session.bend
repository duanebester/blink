# The session: Clunk's protocol state machine as a pure function. Backend
# messages go in; bytes to send and replies for the caller come out. It runs
# a queue of queries, one at a time, then says goodbye. The IO shell
# (io.bend) only moves bytes between the socket and this.
import Base
import ./bytes.bend as B
import ./frame.bend as F
import ./wire.bend as W
import ./auth.bend as A
import ./rows.bend as R

# A query to run. Simple goes as one Query message and may hold several
# statements. Extended is one statement through Parse, Bind and Execute:
# params fill $1, $2... as text (None is NULL), never spliced into the SQL.
# With fetch > 0 its rows come fetch at a time, each batch asked for after
# the last. With timeout > 0, a server silent that many ms gets a
# CancelRequest, and no more batches are asked for.
type Query is Data:
  Query.Simple{sql: String}
  Query.Extended{sql: String, params: List<&2, Maybe<&2, String>>, fetch: U32, timeout: U32}

# What a caller sees, in order: the replies to its queries. Copy is a row of
# COPY ... TO STDOUT, as the server formats it. Cancelled is Blink giving up
# on a query; the server's error for it may follow. Refused is Blink
# refusing the server during login, such as one whose SCRAM signature is
# wrong; Error is always the server's own.
type Reply is Data:
  Reply.Columns{fields: List<&2, W.Field>}
  Reply.Row{entries: List<&2, R.Entry>}
  Reply.Complete{tag: String}
  Reply.Error{severity: String, code: String, message: String}
  Reply.Notice{severity: String, code: String, message: String}
  Reply.Copy{data: List<&2, U32>}
  Reply.Cancelled{}
  Reply.Refused{reason: String}
  Reply.Closed{reason: String}

# A reply as the session keeps it: a row stays raw cells until the caller
# asks for the replies, which decodes them all at once, in parallel.
type Item is Data:
  Item.Reply{r: Reply}
  Item.Row{fields: List<&2, W.Field>, cells: List<&2, Maybe<&2, List<&2, U32>>>}

# Every item so far, in chunks of up to 1024, so that decoding can split
# them among lanes without a pass over every row. chunk is the newest, with
# size items; chunks are the full ones. All newest-first.
type Log is Data:
  Log{chunk: List<&2, Item>, size: U32, chunks: List<&2, List<&2, Item>>}

def push(l: Log, i: Item) -> Log:
  match l:
    case Log{chunk, +size, chunks}:
      match size:
        case 1024:
          Log{[i], 1, chunk <> chunks}
        case _:
          Log{i <> chunk, (size + 1 : U32), chunks}

# The running query: whether it is a simple query, its batch size (0 for all rows at once), its timeout,
# whether its Sync is sent (the server then answers ReadyForQuery), and
# whether it was cancelled.
type Run is Data:
  Run{simple: Bool, fetch: U32, timeout: U32, synced: Bool, stopped: Bool}

# phase 0 is startup, 1 a query running, 2 done (Terminate sent), 3 failed.
# login is where authentication stands; key is the CancelRequest the server's
# BackendKeyData allows (empty until then); fields are the running
# statement's columns. out is what the shell hasn't sent yet; replies are
# every reply so far, newest-first, rows still undecoded.
type Session is Data:
  Session{phase: U32, login: A.Login, queue: List<&2, Query>, run: Run, key: List<&2, U32>,
    fields: List<&2, W.Field>, out: List<&2, U32>, replies: Log}

def reply(s: Session, r: Reply) -> Session:
  match s:
    case Session{phase, login, queue, run, key, fields, out, replies}:
      Session{phase, login, queue, run, key, fields, out, push(replies, Item.Reply{r})}

# Sync ends a batched query, and every extended query after an error: the
# server skips everything up to it.
def sync(s: Session) -> Session:
  match s:
    case Session{phase, login, queue, Run{simple, fetch, timeout, synced, stopped}, key, fields, out, replies}:
      match synced:
        case True{}:
          Session{phase, login, queue, Run{simple, fetch, timeout, True{}, stopped}, key, fields, out, replies}
        case False{}:
          Session{phase, login, queue, Run{simple, fetch, timeout, True{}, stopped}, key, fields,
            List.append(&2, U32, out, W.sync()), replies}

# A batch is done: ask for the next, or, once cancelled, close the portal.
def suspended(s: Session) -> Session:
  match s:
    case Session{phase, login, queue, Run{simple, +fetch, timeout, synced, stopped}, key, fields, out, replies}:
      match stopped:
        case True{}:
          Session{phase, login, queue, Run{simple, fetch, timeout, True{}, True{}}, key, fields,
            List.concat(&2, U32, [out, W.close(), W.sync()]), replies}
        case False{}:
          Session{phase, login, queue, Run{simple, fetch, timeout, synced, False{}}, key, fields,
            List.concat(&2, U32, [out, W.execute(fetch), W.flush()]), replies}

# A batched query flushes instead of syncing: Sync would end the implicit
# transaction, and the portal with it.
def ending(+fetch: U32) -> List<&2, U32>:
  match fetch:
    case 0:
      W.sync()
    case _:
      W.flush()

# A query's first bytes, and how it runs.
def start(q: Query) -> Run & List<&2, U32>:
  match q:
    case Query.Simple{sql}:
      (Run{True{}, 0, 0, True{}, False{}}, W.query(sql))
    case Query.Extended{sql, params, +fetch, timeout}:
      (Run{False{}, fetch, timeout, U32.is_eq(fetch, 0), False{}},
        List.concat(&2, U32, [W.parse(sql), W.bind(params), W.describe(), W.execute(fetch), ending(fetch)]))

def started(p: Run & List<&2, U32>, login: A.Login, queue: List<&2, Query>, key: List<&2, U32>,
  out: List<&2, U32>, replies: Log) -> Session:
  (run, bytes) = p
  Session{1, login, queue, run, key, Nil{}, List.append(&2, U32, out, bytes), replies}

# The server is ready: send the next query, or say goodbye.
def ready(s: Session) -> Session:
  match s:
    case Session{+phase, login, queue, run, key, fields, out, replies}:
      match phase:
        case 3:
          Session{3, login, queue, run, key, fields, out, replies}
        case _:
          match queue:
            case Nil{}:
              Session{2, login, Nil{}, run, key, fields, List.append(&2, U32, out, W.terminate()), replies}
            case q <> rest:
              started(start(q), login, rest, key, out, replies)

# An error during startup ends the session; during a query it ends only
# that query, and the server is ready again after its Sync.
def error(s: Session, r: Reply) -> Session:
  match s:
    case Session{+phase, login, queue, run, key, fields, out, replies}:
      match phase:
        case 0:
          Session{3, login, queue, run, key, fields, out, push(replies, Item.Reply{r})}
        case _:
          sync(Session{phase, login, queue, run, key, fields, out, push(replies, Item.Reply{r})})

# An authentication request: send auth.bend's answer, or fail the session.
def auth(s: Session, a: A.Answer) -> Session:
  match s:
    case Session{phase, l, queue, run, key, fields, out, replies}:
      match a:
        case A.Answer.Send{login, bytes}:
          Session{0, login, queue, run, key, fields, List.append(&2, U32, out, bytes), replies}
        case A.Answer.Fail{message}:
          Session{3, A.Login.Done{}, queue, run, key, fields, out, push(replies, Item.Reply{Reply.Refused{message}})}

def keyed(s: Session, pid: U32, secret: U32) -> Session:
  match s:
    case Session{phase, login, queue, run, key, fields, out, replies}:
      Session{phase, login, queue, run, W.cancel_request(pid, secret), fields, out, replies}

def columns(s: Session, +fs: List<&2, W.Field>) -> Session:
  match s:
    case Session{phase, login, queue, run, key, fields, out, replies}:
      Session{phase, login, queue, run, key, fs, out, push(replies, Item.Reply{Reply.Columns{fs}})}

def row(s: Session, cells: List<&2, Maybe<&2, List<&2, U32>>>) -> Session:
  match s:
    case Session{phase, login, queue, run, key, +fields, out, replies}:
      Session{phase, login, queue, run, key, fields, out, push(replies, Item.Row{fields, cells})}

# COPY FROM STDIN wants data Blink can't send, so it refuses with CopyFail
# and the server answers with an error. The server ignores a Sync sent
# during copy-in, so an extended query needs another: the error sends it.
def copy_in(s: Session) -> Session:
  match s:
    case Session{phase, login, queue, Run{+simple, fetch, timeout, synced, stopped}, key, fields, out, replies}:
      Session{phase, login, queue, Run{simple, fetch, timeout, simple, stopped}, key, fields,
        List.append(&2, U32, out, W.copy_fail("Blink can't send COPY data")), replies}

def login(s: Session) -> A.Login:
  match s:
    case Session{phase, login, queue, run, key, fields, out, replies}:
      login

def react.go(+s: Session, msg: W.Backend) -> Session:
  match msg:
    case W.Backend.Auth{code, data}:
      auth(s, A.answer(code, data, login(s)))
    case W.Backend.Key{pid, secret}:
      keyed(s, pid, secret)
    case W.Backend.Ready{status}:
      ready(s)
    case W.Backend.Columns{fs}:
      columns(s, fs)
    case W.Backend.Row{cells}:
      row(s, cells)
    case W.Backend.Complete{tag}:
      sync(reply(s, Reply.Complete{tag}))
    case W.Backend.Empty{}:
      sync(s)
    case W.Backend.Suspended{}:
      suspended(s)
    case W.Backend.CopyIn{}:
      copy_in(s)
    case W.Backend.CopyData{data}:
      reply(s, Reply.Copy{data})
    case W.Backend.Error{severity, code, message}:
      error(s, Reply.Error{severity, code, message})
    case W.Backend.Notice{severity, code, message}:
      reply(s, Reply.Notice{severity, code, message})
    case _:
      s

def failed(s: Session) -> Bool:
  match s:
    case Session{phase, login, queue, run, key, fields, out, replies}:
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
  queue: List<&2, Query>) -> Conn:
  Conn{F.new(), Session{0, A.Login.Start{user, password, nonce}, queue,
    Run{True{}, 0, 0, True{}, False{}}, Nil{}, Nil{}, W.startup(user, database), Log{Nil{}, 0, Nil{}}}}

def receive.go(p: List<&2, F.Frame> & F.Rx, se: Session) -> Conn:
  (frames, rx) = p
  Conn{rx, react_frames(se, frames)}

# One read's bytes in.
def receive(c: Conn, chunk: List<&2, U32>) -> Conn:
  match c:
    case Conn{rx, se}:
      receive.go(F.take(F.feed(rx, chunk)), se)

# The bytes left over from the last read, which the next read's buffer
# must start with, and the connection without them.
def pending.go(p: List<&2, U32> & F.Rx, se: Session) -> List<&2, U32> & Conn:
  (rest, rx) = p
  (rest, Conn{rx, se})

def pending(c: Conn) -> List<&2, U32> & Conn:
  match c:
    case Conn{rx, se}:
      pending.go(F.rest(rx), se)

# One read's buffer in: a[0 .. n] is pending's bytes, then the new ones.
def receive_buf(c: Conn, a: Array<U32>, +n: U32) -> Conn:
  match c:
    case Conn{rx, se}:
      receive.go(F.take(F.feed_buf(rx, a, n)), se)

# The bytes to send, and the connection without them.
def take(c: Conn) -> List<&2, U32> & Conn:
  match c:
    case Conn{rx, Session{phase, login, queue, run, key, fields, out, replies}}:
      (out, Conn{rx, Session{phase, login, queue, run, key, fields, Nil{}, replies}})

# ---- decoding the replies

def item(i: Item) -> Reply:
  match i:
    case Item.Reply{r}:
      r
    case Item.Row{fields, cells}:
      Reply.Row{R.record(fields, cells)}

def items(xs: List<&2, Item>) -> List<&2, Reply>:
  match xs:
    case Nil{}:
      Nil{}
    case i <> rest:
      item(i) <> items(rest)

def deal.cons(c: List<&2, Item>, p: List<&2, List<&2, Item>> & List<&2, List<&2, Item>>) ->
  List<&2, List<&2, Item>> & List<&2, List<&2, Item>>:
  (a, b) = p
  (c <> b, a)

# The 1st, 3rd, 5th... chunks and the 2nd, 4th...: two even halves.
def deal(cs: List<&2, List<&2, Item>>) -> List<&2, List<&2, Item>> & List<&2, List<&2, Item>>:
  match cs:
    case Nil{}:
      (Nil{}, Nil{})
    case c <> rest:
      deal.cons(c, deal(rest))

# deal undone: the halves' chunks back in their order.
def merge(a: List<&2, List<&2, Reply>>, b: List<&2, List<&2, Reply>>) -> List<&2, List<&2, Reply>>:
  match a b:
    case x <> t y <> u:
      x <> y <> merge(t, u)
    case x <> t Nil{}:
      x <> t
    case Nil{} y <> u:
      y <> u
    case Nil{} Nil{}:
      Nil{}

# Each chunk (newest-first) as its replies, oldest first.
def chunks(cs: List<&2, List<&2, Item>>) -> List<&2, List<&2, Reply>>:
  match cs:
    case Nil{}:
      Nil{}
    case c <> rest:
      items(List.reverse(&2, Item, c)) <> chunks(rest)

# Decodes dealt halves of the chunks in 2^depth lanes. A row decodes alone,
# so on a native build the lanes run in parallel (Bend's parallel call:
# a b = f() g()).
def decode(depth: Nat, p: List<&2, List<&2, Item>> & List<&2, List<&2, Item>>) -> List<&2, List<&2, Reply>>:
  match depth:
    case 0n:
      (l, r) = p
      merge(chunks(l), chunks(r))
    case 1n+d:
      (l, r) = p
      +e = d
      a b = decode(e, deal(l)) decode(e, deal(r))
      merge(a, b)

# Every reply so far, oldest first, rows decoded in 32 lanes.
def replies(c: Conn) -> List<&2, Reply>:
  match c:
    case Conn{rx, Session{phase, login, queue, run, key, fields, out, Log{chunk, size, cs}}}:
      List.concat(&2, Reply, decode(5n, deal(List.reverse(&2, List<&2, Item>, chunk <> cs))))

# The socket failed or closed under the session.
def closed(c: Conn, reason: String) -> Conn:
  match c:
    case Conn{rx, Session{phase, login, queue, run, key, fields, out, rs}}:
      Conn{rx, Session{3, login, queue, run, key, fields, out, push(rs, Item.Reply{Reply.Closed{reason}})}}

# Whether the session still wants the socket.
def open(c: Conn) -> Bool:
  match c:
    case Conn{rx, Session{phase, login, queue, run, key, fields, out, replies}}:
      U32.is_lt(phase, 2)

def deadline.at(+phase: U32, timeout: U32) -> U32:
  match phase:
    case 1:
      timeout
    case _:
      0

# How long to wait for the server before cancelling, in ms; 0 is forever.
# After a cancel the same deadline holds again.
def deadline(c: Conn) -> U32:
  match c:
    case Conn{rx, Session{phase, login, queue, Run{simple, fetch, timeout, synced, stopped}, key, fields, out, replies}}:
      deadline.at(phase, timeout)

# The running query's deadline (above) passed. The first time, it stops
# getting batches, the caller gets Cancelled, and the shell gets the
# CancelRequest to send on a new connection (empty if the server gave no
# key). The second time, the server ignored the cancel, or it never arrived:
# the connection closes.
def cancel(c: Conn) -> List<&2, U32> & Conn:
  match c:
    case Conn{rx, Session{phase, login, queue, Run{simple, fetch, timeout, synced, stopped}, +key, fields, out, replies}}:
      match stopped:
        case True{}:
          (Nil{}, closed(Conn{rx, Session{phase, login, queue, Run{simple, fetch, timeout, synced, True{}}, key,
            fields, out, replies}}, "no answer after the cancel"))
        case False{}:
          (key, Conn{rx, Session{phase, login, queue, Run{simple, fetch, timeout, synced, True{}}, key, fields, out,
            push(replies, Item.Reply{Reply.Cancelled{}})}})

# ---- showing replies, one line each

def show.fields(fs: List<&2, W.Field>) -> String:
  match fs:
    case Nil{}:
      ""
    case W.Field{name, oid} <> rest:
      " " ++ name ++ ":" ++ U32.show(oid) ++ show.fields(rest)

def chomp.rev(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> +rest:
      Bool.pick(List<&2, U32>, U32.is_eq(x, 10), rest, x <> rest)

# The bytes without a final newline.
def chomp(xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, chomp.rev(List.reverse(&2, U32, xs)))

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
    case Reply.Copy{data}:
      "copy " ++ B.text(chomp(data))
    case Reply.Cancelled{}:
      "cancelled"
    case Reply.Refused{reason}:
      "refused " ++ reason
    case Reply.Closed{reason}:
      "closed " ++ reason
