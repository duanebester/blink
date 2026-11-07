# The wire protocol (v3): frontend messages -> bytes, and frames -> backend
# messages. Pure. What startup, authentication and simple queries need.
import Base
import ./bytes.bend as B
import ./frame.bend as F

# ---- frontend: messages -> bytes

# A message body behind its length, which counts itself.
def sized(+body: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, B.be32((U32.from_nat(List.length(&2, U32, body)) + 4 : U32)), body)

# Protocol 3.0, asking for UTF8 text, since Blink encodes and decodes UTF-8.
def startup(user: String, database: String) -> List<&2, U32>:
  sized(List.concat(&2, U32, [B.be32(196608), B.cstring("user"), B.cstring(user),
    B.cstring("database"), B.cstring(database), B.cstring("client_encoding"),
    B.cstring("UTF8"), [0]]))

# 'Q': a simple query. It may hold several statements.
def query(sql: String) -> List<&2, U32>:
  81 <> sized(B.cstring(sql))

# 'p': a password, an MD5 hash of one, or a SASL step; only the body differs.
def password(bytes: List<&2, U32>) -> List<&2, U32>:
  112 <> sized(List.append(&2, U32, bytes, [0]))

def sasl_initial(mechanism: String, +data: List<&2, U32>) -> List<&2, U32>:
  112 <> sized(List.concat(&2, U32, [B.cstring(mechanism),
    B.be32(U32.from_nat(List.length(&2, U32, data))), data]))

def sasl_response(data: List<&2, U32>) -> List<&2, U32>:
  112 <> sized(data)

# 'X': the polite goodbye before closing the socket.
def terminate() -> List<&2, U32>:
  [88, 0, 0, 0, 4]

# ---- backend: frames -> messages

# A RowDescription column: its name and type OID.
type Field is Data:
  Field{name: String, oid: U32}

type Backend is Data:
  Backend.Auth{code: U32, data: List<&2, U32>}
  Backend.Key{pid: U32, secret: U32}
  Backend.Ready{status: U32}
  Backend.Columns{fields: List<&2, Field>}
  Backend.Row{cells: List<&2, Maybe<&2, List<&2, U32>>>}
  Backend.Complete{tag: String}
  Backend.Error{severity: String, code: String, message: String}
  Backend.Notice{severity: String, code: String, message: String}
  Backend.Other{tag: U32}

# -- RowDescription: a count, then per column a name and 18 bytes, of which
# the type OID is bytes 6 to 9.

def columns.go(n: Nat, c: B.Cut) -> List<&2, Field>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      match c:
        case B.Cut{name, +rest}:
          Field{B.text(name), B.word(List.drop(&2, U32, rest, 6n))}
            <> columns.go(p, B.cut_cstring(List.drop(&2, U32, rest, 18n)))

def columns(body: List<&2, U32>) -> List<&2, Field>:
  match body:
    case a <> b <> rest:
      columns.go(U32.to_nat(B.u16(a, b)), B.cut_cstring(rest))
    case _:
      Nil{}

# -- DataRow: a count, then per column a length (-1 is NULL) and its bytes.

type Cell is Data:
  Cell{value: Maybe<&2, List<&2, U32>>, rest: List<&2, U32>}

def cell.cut(c: B.Cut) -> Cell:
  match c:
    case B.Cut{v, rest}:
      Cell{Some{v}, rest}

def cell.at(null: Bool, +len: U32, rest: List<&2, U32>) -> Cell:
  match null:
    case True{}:
      Cell{None{}, rest}
    case False{}:
      cell.cut(B.split(rest, U32.to_nat(len)))

def cell(xs: List<&2, U32>) -> Cell:
  match xs:
    case a <> b <> c <> d <> rest:
      +len = B.u32(a, b, c, d)
      cell.at(U32.is_eq(len, 4294967295), len, rest)
    case _:
      Cell{None{}, Nil{}}

def cells.go(n: Nat, c: Cell) -> List<&2, Maybe<&2, List<&2, U32>>>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      match c:
        case Cell{v, rest}:
          v <> cells.go(p, cell(rest))

def cells(body: List<&2, U32>) -> List<&2, Maybe<&2, List<&2, U32>>>:
  match body:
    case a <> b <> rest:
      cells.go(U32.to_nat(B.u16(a, b)), cell(rest))
    case _:
      Nil{}

# -- ErrorResponse and NoticeResponse: (type byte, cstring) fields up to a
# NUL. S is the severity, C the SQLSTATE code and M the message. A fold, so
# no recursion of its own; kind 0 waits for a field's type byte.

type Fields is Data:
  Fields{kind: U32, cur: List<&2, U32>, severity: String, code: String, message: String}

def fields.keep(+kind: U32, v: String, severity: String, code: String, message: String) -> Fields:
  match kind:
    case 83:
      Fields{0, Nil{}, v, code, message}
    case 67:
      Fields{0, Nil{}, severity, v, message}
    case 77:
      Fields{0, Nil{}, severity, code, v}
    case _:
      Fields{0, Nil{}, severity, code, message}

def fields.at(nul: Bool, start: Bool, +b: U32, +kind: U32, cur: List<&2, U32>,
  severity: String, code: String, message: String) -> Fields:
  match nul start:
    case True{} True{}:
      Fields{0, Nil{}, severity, code, message}
    case True{} False{}:
      fields.keep(kind, B.text(List.reverse(&2, U32, cur)), severity, code, message)
    case False{} True{}:
      Fields{b, Nil{}, severity, code, message}
    case False{} False{}:
      Fields{kind, b <> cur, severity, code, message}

def fields.step(f: Fields, +b: U32) -> Fields:
  match f:
    case Fields{+kind, cur, severity, code, message}:
      fields.at(U32.is_eq(b, 0), U32.is_eq(kind, 0), b, kind, cur, severity, code, message)

def fields(body: List<&2, U32>) -> Fields:
  List.foldl(~&2, ~U32, ~Fields, ~(f => b => fields.step(f, b)), body,
    Fields{0, Nil{}, "", "", ""})

def error(f: Fields) -> Backend:
  match f:
    case Fields{kind, cur, severity, code, message}:
      Backend.Error{severity, code, message}

def notice(f: Fields) -> Backend:
  match f:
    case Fields{kind, cur, severity, code, message}:
      Backend.Notice{severity, code, message}

# -- CommandComplete: a cstring

def first(c: B.Cut) -> String:
  match c:
    case B.Cut{s, rest}:
      B.text(s)

# -- Authentication: a request code, then what that request carries (an MD5
# salt, SASL mechanisms or SASL data).

def auth(body: List<&2, U32>) -> Backend:
  match body:
    case a <> b <> c <> d <> rest:
      Backend.Auth{B.u32(a, b, c, d), rest}
    case _:
      Backend.Other{82}

def key(body: List<&2, U32>) -> Backend:
  match body:
    case a <> b <> c <> d <> rest:
      Backend.Key{B.u32(a, b, c, d), B.word(rest)}
    case _:
      Backend.Other{75}

def ready(body: List<&2, U32>) -> Backend:
  match body:
    case Nil{}:
      Backend.Ready{0}
    case s <> rest:
      Backend.Ready{s}

# A frame as the message it carries.
def decode(f: F.Frame) -> Backend:
  match f:
    case F.Frame{+tag, +body}:
      match tag:
        case 82:
          auth(body)
        case 75:
          key(body)
        case 90:
          ready(body)
        case 84:
          Backend.Columns{columns(body)}
        case 68:
          Backend.Row{cells(body)}
        case 67:
          Backend.Complete{first(B.cut_cstring(body))}
        case 69:
          error(fields(body))
        case 78:
          notice(fields(body))
        case _:
          Backend.Other{tag}
