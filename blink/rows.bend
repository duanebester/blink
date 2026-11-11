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

# Text stays UTF-8 bytes until read, a slice of the read it came in:
# Bytes.utf8 turns it into a String.
type Value is Data:
  Value.Null{}
  Value.Bool{b: Bool}
  Value.Int{n: Int}
  Value.Text{bytes: Bytes}

type Entry is Data:
  Entry{name: String, value: Value}

# ---- values

def int.sign(neg: Bool, +bytes: Bytes) -> Maybe<&2, Int>:
  match neg:
    case True{}:
      Maybe.map(&2, U32, Int, n => Int{True{}, n}, U32.read(Bytes.utf8(Bytes.drop(bytes, 1n))))
    case False{}:
      Maybe.map(&2, U32, Int, n => Int{False{}, n}, U32.read(Bytes.utf8(bytes)))

def int.at(empty: Bool, +bytes: Bytes) -> Maybe<&2, Int>:
  match empty:
    case True{}:
      None{}
    case False{}:
      int.sign(U32.is_eq(Bytes.get(bytes, 0n), 45), bytes)

def int.of(+bytes: Bytes) -> Maybe<&2, Int>:
  int.at(Nat.is_eq(Bytes.length(bytes), 0n), bytes)

# "-42" -> Int{True, 42}; None if it doesn't parse.
def int(bytes: Bytes) -> Maybe<&2, Int>:
  int.of(bytes)

# "t" is true; an empty cell reads as byte 0, false.
def bool(bytes: Bytes) -> Bool:
  U32.is_eq(Bytes.get(bytes, 0n), 116)

def value.int(m: Maybe<&2, Int>, +bytes: Bytes) -> Value:
  match m:
    case Some{n}:
      Value.Int{n}
    case None{}:
      Value.Text{bytes}

def value.text(+oid: U32, +bytes: Bytes) -> Value:
  match oid:
    case 16:
      Value.Bool{bool(bytes)}
    case 21:
      value.int(int(bytes), bytes)
    case 23:
      value.int(int(bytes), bytes)
    case _:
      Value.Text{bytes}

# One column's value from its type OID and its cell (None is NULL). int8,
# numeric, floats, dates and the rest stay text for now.
def value(+oid: U32, cell: Maybe<&2, Bytes>) -> Value:
  match cell:
    case None{}:
      Value.Null{}
    case Some{bytes}:
      value.text(oid, bytes)

# ---- untyped records

# A DataRow's cells, named and decoded by the RowDescription's fields.
def record(fields: List<&2, W.Field>, cells: List<&2, Maybe<&2, Bytes>>) -> List<&2, Entry>:
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
    case Value.Text{bytes}:
      Bytes.utf8(bytes)

def show.go(es: List<&2, Entry>) -> String:
  match es:
    case Nil{}:
      ""
    case Entry{name, v} <> rest:
      "|" ++ show.value(v) ++ show.go(rest)

# A record as a line of `psql -A`: values joined by "|".
def show(es: List<&2, Entry>) -> String:
  String.drop(show.go(es), 1n)

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

def col(c: Col, cell: Maybe<&2, Bytes>) -> ColT(c):
  match c:
    case Col.Int{}:
      Maybe.bind(&2, Bytes, Int, cell, int)
    case Col.Text{}:
      Maybe.map(&2, Bytes, String, Bytes.utf8, cell)
    case Col.Bool{}:
      Maybe.map(&2, Bytes, Bool, bool, cell)

# A DataRow's cells as the schema's tuple; a missing cell is None.
def decode(cs: List<&2, Col>, cells: List<&2, Maybe<&2, Bytes>>) -> Row(cs):
  match cs cells:
    case Nil{} _:
      Unit{}
    case c <> rest Nil{}:
      (col(c, None{}), decode(rest, Nil{}))
    case c <> rest h <> t:
      (col(c, h), decode(rest, t))
