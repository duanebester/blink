import Base
import ./pg.bend as Pg

# LAW: how the bytes are cut into reads does not change what the framer sees.
law feed_split:
  for a: List<&2, U32>
  for b: List<&2, U32>
  for st: Pg.Rx
  {Pg.rx.feed(Pg.rx.feed(st, a), b) == Pg.rx.feed(st, List.append(&2, U32, a, b)) : Pg.Rx}

def feed_split(a, b, st):
  match a:
    case Nil{}:
      {==}
    case +h <> t:
      feed_split(t, b, Pg.rx.step(st, h))

# A first-order schema, and the row type it denotes (dependent types).
type Col is Data:
  CU32{}
  CText{}

def ColT(c: Col) -> Type:
  match c:
    case CU32{}:
      Maybe<&2, U32>
    case CText{}:
      Maybe<&2, String>

def Row(cs: List<&2, Col>) -> Type:
  match cs:
    case Nil{}:
      Unit
    case c <> rest:
      ColT(c) & Row(rest)

def col.u32(v: Maybe<&2, String>) -> Maybe<&2, U32>:
  match v:
    case None{}:
      None{}
    case Some{s}:
      U32.read(s)

def col(c: Col, v: Maybe<&2, String>) -> ColT(c):
  match c:
    case CU32{}:
      col.u32(v)
    case CText{}:
      v

# cells -> a typed row, for any schema
def decode(cs: List<&2, Col>, cells: List<&2, Maybe<&2, String>>) -> Row(cs):
  match cs cells:
    case Nil{} _:
      Unit{}
    case c <> rest Nil{}:
      (col(c, None{}), decode(rest, Nil{}))
    case c <> rest h <> t:
      (col(c, h), decode(rest, t))

def main() -> Row([CU32{}, CText{}, CU32{}]):
  decode([CU32{}, CText{}, CU32{}], [Some{"42"}, Some{"héllo"}, None{}])
