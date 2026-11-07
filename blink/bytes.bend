# Bytes: the wire's raw material. A byte is a U32 from 0 to 255 in a
# List<&2, U32>, the form TCP.send_bytes and TCP.recv_bytes use. Everything
# here is pure.
import Base

# ---- writing

def be32(+n: U32) -> List<&2, U32>:
  [((n >> 24n) .&. 255 : U32), ((n >> 16n) .&. 255 : U32), ((n >> 8n) .&. 255 : U32),
    (n .&. 255 : U32)]

# One code point as UTF-8.
def utf8.char(+c: U32) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_lt(c, 128), [c],
    Bool.pick(List<&2, U32>, U32.is_lt(c, 2048),
      [(192 .|. (c >> 6n) : U32), (128 .|. (c .&. 63) : U32)],
      Bool.pick(List<&2, U32>, U32.is_lt(c, 65536),
        [(224 .|. (c >> 12n) : U32), (128 .|. ((c >> 6n) .&. 63) : U32),
          (128 .|. (c .&. 63) : U32)],
        [(240 .|. (c >> 18n) : U32), (128 .|. ((c >> 12n) .&. 63) : U32),
          (128 .|. ((c >> 6n) .&. 63) : U32), (128 .|. (c .&. 63) : U32)])))

# A String (code points) as UTF-8 bytes. Postgres sizes messages in bytes.
def utf8(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{+c}, t}:
      List.append(&2, U32, utf8.char(c), utf8(t))

# A NUL-terminated string, as the protocol writes names and SQL.
def cstring(s: String) -> List<&2, U32>:
  List.append(&2, U32, utf8(s), [0])

# ---- reading

def u16(+a: U32, +b: U32) -> U32:
  ((a << 8n) .|. b : U32)

def u32(+a: U32, +b: U32, +c: U32, +d: U32) -> U32:
  (((a << 24n) .|. (b << 16n)) .|. ((c << 8n) .|. d) : U32)

# The first four bytes as a big-endian word, 0 if there are fewer.
def word(xs: List<&2, U32>) -> U32:
  match xs:
    case a <> b <> c <> d <> rest:
      u32(a, b, c, d)
    case _:
      0

# A cut of a byte list: the bytes taken and the rest.
type Cut is Data:
  Cut{head: List<&2, U32>, rest: List<&2, U32>}

def split.cons(h: U32, c: Cut) -> Cut:
  match c:
    case Cut{a, b}:
      Cut{h <> a, b}

# The first n bytes and the rest (all of them if there are fewer).
def split(xs: List<&2, U32>, n: Nat) -> Cut:
  match xs n:
    case Nil{} _:
      Cut{Nil{}, Nil{}}
    case h <> t 0n:
      Cut{Nil{}, h <> t}
    case h <> t 1n+p:
      split.cons(h, split(t, p))

def cstring.go(xs: List<&2, U32>, acc: List<&2, U32>) -> Cut:
  match xs:
    case Nil{}:
      Cut{List.reverse(&2, U32, acc), Nil{}}
    case +h <> t:
      match h:
        case 0:
          Cut{List.reverse(&2, U32, acc), t}
        case _:
          cstring.go(t, h <> acc)

# The bytes up to the next NUL, and the bytes after it.
def cut_cstring(xs: List<&2, U32>) -> Cut:
  cstring.go(xs, Nil{})

# ---- UTF-8 decoding
#
# From Bend's demos/io_http_fetch (Apache-2.0): WHATWG's replacement policy,
# as Bend's own TCP text codec decodes, including an incomplete last
# character. A fold over the bytes, so it needs no recursion of its own.

type Utf8 is Data:
  Utf8{left: U32, code: U32, low: U32, high: U32, text: String}

def utf8.start(+b: U32, +text: String) -> Utf8:
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

def utf8.more(+b: U32, +left: U32, +code: U32, +text: String, valid: Bool) -> Utf8:
  match valid:
    case False{}:
      utf8.start(b, SCon{Chr{65533}, text})
    case True{}:
      +next = U32.sub(left, 1)
      +value = U32.or(U32.shln(code, 6n), U32.and(b, 63))
      Utf8{next, value, 128, 191,
        Bool.pick(String, U32.is_zero(next), SCon{Chr{value}, text}, text)}

def utf8.byte(state: Utf8, +b: U32) -> Utf8:
  match state:
    case Utf8{left, code, low, high, text}:
      match left:
        case 0:
          utf8.start(b, text)
        case _:
          utf8.more(b, left, code, text, Bool.and(U32.is_ge(b, low), U32.is_le(b, high)))

def utf8.finish(state: Utf8) -> String:
  match state:
    case Utf8{left, code, low, high, +text}:
      String.reverse(Bool.pick(String, U32.is_zero(left), text, SCon{Chr{65533}, text}))

# UTF-8 bytes as a String.
def text(bytes: List<&2, U32>) -> String:
  utf8.finish(List.foldl(~&2, ~U32, ~Utf8, ~(state => b => utf8.byte(state, b)), bytes,
    Utf8{0, 0, 128, 191, ""}))
