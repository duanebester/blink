# Rows: messages -> records. Values arrive in text format (Blink asks for
# no other), so each type parses its text, chosen by the column's type OID.
# Two shapes: an untyped record of named Values, and a typed Row computed
# from a schema (a dependent type). Pure.
import Base
import ./bytes.bend as B
import ./wire.bend as W

# An int2 or int4. Bend has no signed integers yet, so a sign and a
# magnitude; |int4| fits a U32.
type Int is Data:
  Int{neg: Bool, abs: U32}

type Value is Data:
  Value.Null{}
  Value.Bool{b: Bool}
  Value.Int{n: Int}
  Value.Text{s: String}

type Entry is Data:
  Entry{name: String, value: Value}

# ---- values

def int.of(neg: Bool, m: Maybe<&2, U32>) -> Maybe<&2, Int>:
  match m:
    case None{}:
      None{}
    case Some{abs}:
      Some{Int{neg, abs}}

# "-42" -> Int{True, 42}; None if it doesn't parse.
def int(bytes: List<&2, U32>) -> Maybe<&2, Int>:
  match bytes:
    case Nil{}:
      None{}
    case +h <> t:
      match h:
        case 45:
          int.of(True{}, U32.read(B.text(t)))
        case _:
          int.of(False{}, U32.read(B.text(h <> t)))

def bool(bytes: List<&2, U32>) -> Bool:
  match bytes:
    case Nil{}:
      False{}
    case h <> t:
      U32.is_eq(h, 116)

def value.int(m: Maybe<&2, Int>, +bytes: List<&2, U32>) -> Value:
  match m:
    case Some{n}:
      Value.Int{n}
    case None{}:
      Value.Text{B.text(bytes)}

def value.text(+oid: U32, +bytes: List<&2, U32>) -> Value:
  match oid:
    case 16:
      Value.Bool{bool(bytes)}
    case 21:
      value.int(int(bytes), bytes)
    case 23:
      value.int(int(bytes), bytes)
    case _:
      Value.Text{B.text(bytes)}

# One column's value from its type OID and its cell (None is NULL). int8,
# numeric, floats, dates and the rest stay text for now.
def value(+oid: U32, cell: Maybe<&2, List<&2, U32>>) -> Value:
  match cell:
    case None{}:
      Value.Null{}
    case Some{bytes}:
      value.text(oid, bytes)

# ---- untyped records

# A DataRow's cells, named and decoded by the RowDescription's fields.
def record(fields: List<&2, W.Field>, cells: List<&2, Maybe<&2, List<&2, U32>>>) -> List<&2, Entry>:
  match fields cells:
    case W.Field{name, oid} <> fs c <> cs:
      Entry{name, value(oid, c)} <> record(fs, cs)
    case _ _:
      Nil{}

# A value as psql's unaligned output writes it: NULL is empty.
def show.value(v: Value) -> String:
  match v:
    case Value.Null{}:
      ""
    case Value.Bool{True{}}:
      "t"
    case Value.Bool{False{}}:
      "f"
    case Value.Int{Int{True{}, abs}}:
      "-" ++ U32.show(abs)
    case Value.Int{Int{False{}, abs}}:
      U32.show(abs)
    case Value.Text{s}:
      s

def show.go(es: List<&2, Entry>) -> String:
  match es:
    case Nil{}:
      ""
    case Entry{name, v} <> rest:
      "|" ++ show.value(v) ++ show.go(rest)

# A record as a line of `psql -A`: values joined by "|".
def show(es: List<&2, Entry>) -> String:
  match es:
    case Nil{}:
      ""
    case Entry{name, v} <> rest:
      show.value(v) ++ show.go(rest)

# ---- typed rows

# A schema is a list of Cols; Row(schema) is the Bend type it denotes, so
# decode(schema, cells) hands back exactly that tuple. It does not check
# the columns' OIDs against the schema yet.
type Col is Data:
  Col.Int{}
  Col.Text{}
  Col.Bool{}

def ColT(c: Col) -> Type:
  match c:
    case Col.Int{}:
      Maybe<&2, Int>
    case Col.Text{}:
      Maybe<&2, String>
    case Col.Bool{}:
      Maybe<&2, Bool>

def Row(cs: List<&2, Col>) -> Type:
  match cs:
    case Nil{}:
      Unit
    case c <> rest:
      ColT(c) & Row(rest)

def col.int(cell: Maybe<&2, List<&2, U32>>) -> Maybe<&2, Int>:
  match cell:
    case None{}:
      None{}
    case Some{bytes}:
      int(bytes)

def col.text(cell: Maybe<&2, List<&2, U32>>) -> Maybe<&2, String>:
  match cell:
    case None{}:
      None{}
    case Some{bytes}:
      Some{B.text(bytes)}

def col.bool(cell: Maybe<&2, List<&2, U32>>) -> Maybe<&2, Bool>:
  match cell:
    case None{}:
      None{}
    case Some{bytes}:
      Some{bool(bytes)}

def col(c: Col, cell: Maybe<&2, List<&2, U32>>) -> ColT(c):
  match c:
    case Col.Int{}:
      col.int(cell)
    case Col.Text{}:
      col.text(cell)
    case Col.Bool{}:
      col.bool(cell)

# A DataRow's cells as the schema's tuple; a missing cell is None.
def decode(cs: List<&2, Col>, cells: List<&2, Maybe<&2, List<&2, U32>>>) -> Row(cs):
  match cs cells:
    case Nil{} _:
      Unit{}
    case c <> rest Nil{}:
      (col(c, None{}), decode(rest, Nil{}))
    case c <> rest h <> t:
      (col(c, h), decode(rest, t))
