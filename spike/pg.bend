# Spike: bytes -> frames -> messages -> rows as pure transforms, with a thin
# IO shell. Trust auth, one simple query. Scratch only.
import Base

# ---- encode (pure)

def be32(+n: U32) -> List<&2, U32>:
  [((n >> 24n) .&. 255 : U32), ((n >> 16n) .&. 255 : U32), ((n >> 8n) .&. 255 : U32), (n .&. 255 : U32)]

def utf8.enc(+c: U32) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_lt(c, 128), [c],
    Bool.pick(List<&2, U32>, U32.is_lt(c, 2048),
      [(192 .|. (c >> 6n) : U32), (128 .|. (c .&. 63) : U32)],
      Bool.pick(List<&2, U32>, U32.is_lt(c, 65536),
        [(224 .|. (c >> 12n) : U32), (128 .|. ((c >> 6n) .&. 63) : U32), (128 .|. (c .&. 63) : U32)],
        [(240 .|. (c >> 18n) : U32), (128 .|. ((c >> 12n) .&. 63) : U32), (128 .|. ((c >> 6n) .&. 63) : U32), (128 .|. (c .&. 63) : U32)])))

def utf8(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{+c}, t}:
      List.append(&2, U32, utf8.enc(c), utf8(t))

def cstr(s: String) -> List<&2, U32>:
  List.append(&2, U32, utf8(s), [0])

def sized(+body: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, be32((U32.from_nat(List.length(&2, U32, body)) + 4 : U32)), body)

def startup(user: String, db: String) -> List<&2, U32>:
  sized(List.concat(&2, U32, [be32(196608), cstr("user"), cstr(user), cstr("database"), cstr(db),
    cstr("client_encoding"), cstr("UTF8"), [0]]))

def query(sql: String) -> List<&2, U32>:
  81 <> sized(cstr(sql))

# ---- framing: a byte-at-a-time fold, so state carries across reads (pure)

type Frame is Data:
  Frame{tag: U32, body: List<&2, U32>}

# phase 0: tag; 1..4: length bytes; 5: body, need bytes left. body and done
# are newest-first.
type Rx is Data:
  Rx{phase: U32, tag: U32, need: U32, body: List<&2, U32>, done: List<&2, Frame>}

def rx.emit(full: Bool, +tag: U32, need: U32, body: List<&2, U32>, done: List<&2, Frame>) -> Rx:
  match full:
    case True{}:
      Rx{0, 0, 0, Nil{}, Frame{tag, List.reverse(&2, U32, body)} <> done}
    case False{}:
      Rx{5, tag, need, body, done}

def rx.len_end(last: Bool, +ph: U32, tag: U32, +n: U32, done: List<&2, Frame>) -> Rx:
  match last:
    case True{}:
      rx.emit(U32.is_eq(n, 4), tag, (n - 4 : U32), Nil{}, done)
    case False{}:
      Rx{(ph + 1 : U32), tag, n, Nil{}, done}

def rx.go(start: Bool, inbody: Bool, +ph: U32, tag: U32, +need: U32, body: List<&2, U32>,
  done: List<&2, Frame>, +b: U32) -> Rx:
  match start inbody:
    case True{} _:
      Rx{1, b, 0, Nil{}, done}
    case False{} True{}:
      rx.emit(U32.is_eq(need, 1), tag, (need - 1 : U32), b <> body, done)
    case False{} False{}:
      rx.len_end(U32.is_eq(ph, 4), ph, tag, (need * 256 + b : U32), done)

def rx.step(st: Rx, +b: U32) -> Rx:
  match st:
    case Rx{+ph, tag, need, body, done}:
      rx.go(U32.is_eq(ph, 0), U32.is_eq(ph, 5), ph, tag, need, body, done, b)

def rx.feed(st: Rx, chunk: List<&2, U32>) -> Rx:
  List.foldl(~&2, ~U32, ~Rx, ~(s => b => rx.step(s, b)), chunk, st)

# ---- decode (pure)

type Str is Data:
  Str{s: List<&2, U32>, rest: List<&2, U32>}

def cstr.go(xs: List<&2, U32>, acc: List<&2, U32>) -> Str:
  match xs:
    case Nil{}:
      Str{List.reverse(&2, U32, acc), Nil{}}
    case +h <> t:
      match h:
        case 0:
          Str{List.reverse(&2, U32, acc), t}
        case _:
          cstr.go(t, h <> acc)

type Utf8 is Data:
  Utf8{left: U32, code: U32, low: U32, high: U32, text: String}

def utf8_start(+b: U32, +text: String) -> Utf8:
  +left = Bool.pick(U32, U32.is_lt(b, 224), 1,
    Bool.pick(U32, U32.is_lt(b, 240), 2, 3))
  Bool.pick(Utf8, U32.is_lt(b, 128),
    Utf8{0, 0, 128, 191, SCon{Chr{b}, text}},
    Bool.pick(Utf8, Bool.or(U32.is_lt(b, 194), U32.is_gt(b, 244)),
      Utf8{0, 0, 128, 191, SCon{Chr{65533}, text}},
      Utf8{left, U32.and(b, U32.shrn(63, U32.to_nat(left))),
        Bool.pick(U32, U32.is_eq(b, 224), 160,
          Bool.pick(U32, U32.is_eq(b, 240), 144, 128)),
        Bool.pick(U32, U32.is_eq(b, 237), 159,
          Bool.pick(U32, U32.is_eq(b, 244), 143, 191)), text}))

def utf8_more(+b: U32, +left: U32, +code: U32, +text: String,
  valid: Bool) -> Utf8:
  match valid:
    case False{}:
      utf8_start(b, SCon{Chr{65533}, text})
    case True{}:
      +next = U32.sub(left, 1)
      +value = U32.or(U32.shln(code, 6n), U32.and(b, 63))
      Utf8{next, value, 128, 191,
        Bool.pick(String, U32.is_zero(next), SCon{Chr{value}, text}, text)}

def utf8_byte(state: Utf8, +b: U32) -> Utf8:
  match state:
    case Utf8{left, code, low, high, text}:
      match left:
        case 0:
          utf8_start(b, text)
        case _:
          utf8_more(b, left, code, text,
            Bool.and(U32.is_ge(b, low), U32.is_le(b, high)))

def utf8_finish(state: Utf8) -> String:
  match state:
    case Utf8{left, code, low, high, +text}:
      String.reverse(Bool.pick(String, U32.is_zero(left), text,
        SCon{Chr{65533}, text}))

def text.go(bytes: List<&2, U32>) -> String:
  utf8_finish(List.foldl(~&2, ~U32, ~Utf8, ~(state => b => utf8_byte(state, b)), bytes,
    Utf8{0, 0, 128, 191, ""}))

def rd.fields(n: Nat, s: Str) -> List<&2, String>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      match s:
        case Str{name, rest}:
          text.go(name) <> rd.fields(p, cstr.go(List.drop(&2, U32, rest, 18n), Nil{}))

def rowdesc(body: List<&2, U32>) -> List<&2, String>:
  match body:
    case Nil{}:
      Nil{}
    case +a <> b_rest:
      match b_rest:
        case Nil{}:
          Nil{}
        case +b <> rest:
          rd.fields(U32.to_nat((a * 256 + b : U32)), cstr.go(rest, Nil{}))

type Cut is Data:
  Cut{head: List<&2, U32>, rest: List<&2, U32>}

def cut.cons(h: U32, c: Cut) -> Cut:
  match c:
    case Cut{a, b}:
      Cut{h <> a, b}

def split(xs: List<&2, U32>, n: Nat) -> Cut:
  match xs n:
    case Nil{} _:
      Cut{Nil{}, Nil{}}
    case h <> t 0n:
      Cut{Nil{}, h <> t}
    case h <> t 1n+p:
      cut.cons(h, split(t, p))

type Cell is Data:
  Cell{val: Maybe<&2, String>, rest: List<&2, U32>}

def cell.of(c: Cut) -> Cell:
  match c:
    case Cut{v, rest}:
      Cell{Some{text.go(v)}, rest}

def cell(xs: List<&2, U32>) -> Cell:
  match xs:
    case a <> b <> c <> d <> +rest:
      +len = (((a << 24n) .|. (b << 16n)) .|. ((c << 8n) .|. d) : U32)
      Bool.pick(Cell, U32.is_eq(len, 4294967295), Cell{None{}, rest},
        cell.of(split(rest, U32.to_nat(len))))
    case _:
      Cell{None{}, Nil{}}

def dr.vals(n: Nat, c: Cell) -> List<&2, Maybe<&2, String>>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      match c:
        case Cell{v, rest}:
          v <> dr.vals(p, cell(rest))

def datarow(body: List<&2, U32>) -> List<&2, Maybe<&2, String>>:
  match body:
    case a <> b <> rest:
      dr.vals(U32.to_nat((a * 256 + b : U32)), cell(rest))
    case _:
      Nil{}

def show.val(v: Maybe<&2, String>) -> String:
  match v:
    case None{}:
      "NULL"
    case Some{s}:
      s

def show.row(names: List<&2, String>, vals: List<&2, Maybe<&2, String>>) -> String:
  match names vals:
    case +n <> ns +v <> vs:
      n ++ "=" ++ show.val(v) ++ " " ++ show.row(ns, vs)
    case _ _:
      ""

# ---- the protocol state machine (pure): frames in, bytes out

# phase 0 startup, 1 querying, 2 done, 3 failed. out and log newest-first.
type Sess is Data:
  Sess{phase: U32, names: List<&2, String>, out: List<&2, U32>, log: List<&2, String>}

def react.ready(ph: U32, names: List<&2, String>, out: List<&2, U32>, log: List<&2, String>) -> Sess:
  match ph:
    case 0:
      Sess{1, names, List.append(&2, U32, out, query("SELECT 1::int4 AS one, 'héllo'::text AS t, NULL AS n UNION ALL SELECT 2, 'wörld', NULL")), "ready" <> log}
    case _:
      Sess{2, names, out, "done" <> log}

def react(se: Sess, fr: Frame) -> Sess:
  match se fr:
    case Sess{+ph, +names, out, log} Frame{+tag, +body}:
      match tag:
        case 90:
          react.ready(ph, names, out, log)
        case 84:
          Sess{ph, rowdesc(body), out, log}
        case 68:
          Sess{ph, names, out, show.row(names, datarow(body)) <> log}
        case 82:
          Sess{ph, names, out, ("auth request " ++ U32.show(U32.from_nat(List.length(&2, U32, body)))) <> log}
        case 69:
          Sess{3, names, out, "server error" <> log}
        case _:
          Sess{ph, names, out, log}

# ---- the IO shell: move bytes, nothing else

def prints(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case h <> t:
      do IO<Unit>:
        IO.print(h)
        prints(t)

def rx.take(st: Rx) -> List<&2, Frame> & Rx:
  match st:
    case Rx{ph, tag, need, body, done}:
      (List.reverse(&2, Frame, done), Rx{ph, tag, need, body, Nil{}})

def sess.take(se: Sess) -> (List<&2, U32> & List<&2, String>) & Sess:
  match se:
    case Sess{ph, names, out, log}:
      ((out, List.reverse(&2, String, log)), Sess{ph, names, Nil{}, Nil{}})

def sess.live(se: Sess) -> Bool:
  match se:
    case Sess{ph, names, out, log}:
      U32.is_lt(ph, 2)

def drive.next(live: Bool, s: Socket, rx: Rx, se: Sess, k: Socket -> Rx -> Sess -> IO(Unit)) -> IO(Unit):
  match live:
    case True{}:
      k(s, rx, se)
    case False{}:
      Socket.close(s)

def drive.sent(m: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, rx: Rx, +se: Sess,
  k: Socket -> Rx -> Sess -> IO(Unit)) -> IO(Unit):
  (s, r) = m
  match r:
    case Done{u}:
      drive.next(sess.live(se), s, rx, se, k)
    case Fail{e}:
      Socket.close(s)

def drive.reacted(s: Socket, rx: Rx, q: (List<&2, U32> & List<&2, String>) & Sess,
  k: Socket -> Rx -> Sess -> IO(Unit)) -> IO(Unit):
  ((out, log), se) = q
  do IO<Unit>:
    prints(log)
    m : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send_bytes(s, out)
    drive.sent(m, rx, se, k)

def drive.framed(s: Socket, p: List<&2, Frame> & Rx, se: Sess, k: Socket -> Rx -> Sess -> IO(Unit)) -> IO(Unit):
  (frames, rx) = p
  drive.reacted(s, rx, sess.take(List.foldl(~&2, ~Frame, ~Sess, ~(a => f => react(a, f)), frames, se)), k)

def drive.chunk(s: Socket, rx: Rx, se: Sess, chunk: List<&2, U32>, k: Socket -> Rx -> Sess -> IO(Unit)) -> IO(Unit):
  drive.framed(s, rx.take(rx.feed(rx, chunk)), se, k)

def drive.got(m: Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>, rx: Rx, se: Sess,
  k: Socket -> Rx -> Sess -> IO(Unit)) -> IO(Unit):
  (s, r) = m
  match r:
    case Done{Some{chunk}}:
      drive.chunk(s, rx, se, chunk, k)
    case Done{None{}}:
      do IO<Unit>:
        IO.print("eof")
        Socket.close(s)
    case Fail{e}:
      do IO<Unit>:
        IO.print("recv failed")
        Socket.close(s)

def drive(fuel: Nat, s: Socket, rx: Rx, se: Sess) -> IO(Unit):
  match fuel:
    case 0n:
      Socket.close(s)
    case 1n+f:
      do IO<Unit>:
        m : Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>> <- TCP.recv_bytes(s, 65536)
        drive.got(m, rx, se, s2 => rx2 => se2 => drive(f, s2, rx2, se2))

def main.go(m: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(Unit):
  (s, r) = m
  drive(1000n, s, Rx{0, 0, 0, Nil{}, Nil{}}, Sess{0, Nil{}, Nil{}, Nil{}})

def main() -> IO(Unit):
  do IO<Unit>:
    c : Socket <- IO.try(Socket, TCP.connect("127.0.0.1", 5432))
    m : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send_bytes(c, startup("trusty", "world"))
    main.go(m)
