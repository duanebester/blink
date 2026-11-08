# The proofs of LAWS.bend. Lemmas first, each a def whose type is the fact
# it proves; a recursive call is the induction hypothesis.
import Base
import ./blink/bytes.bend as B
import ./blink/frame.bend as F
import ./blink/wire.bend as W
import ./blink/auth.bend as A
import ./blink/session.bend as S
import ./LAWS.bend as Laws

# ---- the framer and the connection

# Induction on a: each byte of a steps the framer once on either side.
def Laws.feed_split(a, b, rx):
  match a:
    case Nil{}:
      {==}
    case +h <> t:
      Laws.feed_split(t, b, F.step(rx, h))

# receive_split: the framer only ever puts frames in front of those it
# holds (step_app, feed_app, one case per phase), so frames handed over
# after one read are those it would hold after both; then reverse and fold
# over an append.

# rx with d after the frames it holds.
def app(rx: F.Rx, d: List<&2, F.Frame>) -> F.Rx:
  match rx:
    case F.Rx{phase, tag, need, w, left, cur, cells, done}:
      F.Rx{phase, tag, need, w, left, cur, cells, List.append(&2, F.Frame, done, d)}

def body_app(last: Bool, tag: U32, need: U32, cur: List<&2, U32>, done: List<&2, F.Frame>,
  d: List<&2, F.Frame>) ->
  {F.body(last, tag, need, cur, List.append(&2, F.Frame, done, d)) == app(F.body(last, tag, need, cur, done), d) : F.Rx}:
  match last:
    case True{}:
      {==}
    case False{}:
      {==}

def row_app(last: Bool, phase: F.Phase, need: U32, w: U32, left: U32, cur: List<&2, U32>,
  cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, F.Frame>, d: List<&2, F.Frame>) ->
  {F.row(last, phase, need, w, left, cur, cells, List.append(&2, F.Frame, done, d))
    == app(F.row(last, phase, need, w, left, cur, cells, done), d) : F.Rx}:
  match last:
    case True{}:
      {==}
    case False{}:
      {==}

def cell_app(null: Bool, empty: Bool, len: U32, +need: U32, cells: List<&2, Maybe<&2, List<&2, U32>>>,
  done: List<&2, F.Frame>, d: List<&2, F.Frame>) ->
  {F.cell(null, empty, len, need, cells, List.append(&2, F.Frame, done, d))
    == app(F.cell(null, empty, len, need, cells, done), d) : F.Rx}:
  match null empty:
    case True{} _:
      row_app(U32.is_eq(need, 0), F.Phase.Size1{}, need, 0, 0, Nil{}, None{} <> cells, done, d)
    case False{} True{}:
      row_app(U32.is_eq(need, 0), F.Phase.Size1{}, need, 0, 0, Nil{}, Some{Nil{}} <> cells, done, d)
    case False{} False{}:
      row_app(U32.is_eq(need, 0), F.Phase.Cell{}, need, 0, len, Nil{}, cells, done, d)

def bytes_app(full: Bool, +need: U32, left: U32, cur: List<&2, U32>,
  cells: List<&2, Maybe<&2, List<&2, U32>>>, done: List<&2, F.Frame>, d: List<&2, F.Frame>) ->
  {F.bytes(full, need, left, cur, cells, List.append(&2, F.Frame, done, d))
    == app(F.bytes(full, need, left, cur, cells, done), d) : F.Rx}:
  match full:
    case True{}:
      row_app(U32.is_eq(need, 0), F.Phase.Size1{}, need, 0, 0, Nil{}, Some{List.reverse(&2, U32, cur)} <> cells, done, d)
    case False{}:
      row_app(U32.is_eq(need, 0), F.Phase.Cell{}, need, 0, left, cur, cells, done, d)

def length_app(row: Bool, empty: Bool, tag: U32, need: U32, done: List<&2, F.Frame>, d: List<&2, F.Frame>) ->
  {F.length(row, empty, tag, need, List.append(&2, F.Frame, done, d))
    == app(F.length(row, empty, tag, need, done), d) : F.Rx}:
  match row empty:
    case True{} True{}:
      {==}
    case True{} False{}:
      {==}
    case False{} True{}:
      {==}
    case False{} False{}:
      {==}

def word_app(+need: U32, phase: F.Phase, w: U32, cells: List<&2, Maybe<&2, List<&2, U32>>>,
  done: List<&2, F.Frame>, d: List<&2, F.Frame>) ->
  {F.word(need, phase, w, cells, List.append(&2, F.Frame, done, d))
    == app(F.word(need, phase, w, cells, done), d) : F.Rx}:
  row_app(U32.is_eq(need, 1), phase, (need - 1 : U32), w, 0, Nil{}, cells, done, d)

# The framer only ever puts frames in front of those it holds.
def step_app(rx: F.Rx, +b: U32, d: List<&2, F.Frame>) ->
  {F.step(app(rx, d), b) == app(F.step(rx, b), d) : F.Rx}:
  match rx:
    case F.Rx{phase, +tag, +need, +w, +left, cur, cells, done}:
      match phase:
        case F.Phase.Tag{}:
          {==}
        case F.Phase.Len1{}:
          {==}
        case F.Phase.Len2{}:
          {==}
        case F.Phase.Len3{}:
          {==}
        case F.Phase.Len4{}:
          +n = (U32.max(((w << 8n) .|. b : U32), 4) - 4 : U32)
          length_app(U32.is_eq(tag, 68), U32.is_eq(n, 0), tag, n, done, d)
        case F.Phase.Body{}:
          body_app(U32.is_eq(need, 1), tag, (need - 1 : U32), b <> cur, done, d)
        case F.Phase.Count1{}:
          word_app(need, F.Phase.Count2{}, 0, cells, done, d)
        case F.Phase.Count2{}:
          word_app(need, F.Phase.Size1{}, 0, cells, done, d)
        case F.Phase.Size1{}:
          word_app(need, F.Phase.Size2{}, ((w << 8n) .|. b : U32), cells, done, d)
        case F.Phase.Size2{}:
          word_app(need, F.Phase.Size3{}, ((w << 8n) .|. b : U32), cells, done, d)
        case F.Phase.Size3{}:
          word_app(need, F.Phase.Size4{}, ((w << 8n) .|. b : U32), cells, done, d)
        case F.Phase.Size4{}:
          +len = ((w << 8n) .|. b : U32)
          cell_app(U32.is_eq(len, 4294967295), U32.is_eq(len, 0), len, (need - 1 : U32), cells, done, d)
        case F.Phase.Cell{}:
          bytes_app(U32.is_eq(left, 1), (need - 1 : U32), (left - 1 : U32), b <> cur, cells, done, d)

def feed_app(b: List<&2, U32>, +d: List<&2, F.Frame>, +rx: F.Rx) ->
  {F.feed(app(rx, d), b) == app(F.feed(rx, b), d) : F.Rx}:
  match b:
    case Nil{}:
      {==}
    case +h <> t:
      %Equal.sym(F.Rx, F.step(app(rx, d), h), app(F.step(rx, h), d), step_app(rx, h, d))
        : {F.feed(_, t) == app(F.feed(F.step(rx, h), t), d) : F.Rx}
      feed_app(t, d, F.step(rx, h))

def append_assoc(xs: List<&2, F.Frame>, +ys: List<&2, F.Frame>, +zs: List<&2, F.Frame>) ->
  {List.append(&2, F.Frame, List.append(&2, F.Frame, xs, ys), zs)
    == List.append(&2, F.Frame, xs, List.append(&2, F.Frame, ys, zs)) : List<&2, F.Frame>}:
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      %append_assoc(t, ys, zs) : {h <> List.append(&2, F.Frame, List.append(&2, F.Frame, t, ys), zs) == h <> _ : List<&2, F.Frame>}
      {==}

def rev_go(xs: List<&2, F.Frame>, +acc: List<&2, F.Frame>) ->
  {List.reverse.go(&2, F.Frame, xs, acc)
    == List.append(&2, F.Frame, List.reverse.go(&2, F.Frame, xs, Nil{}), acc) : List<&2, F.Frame>}:
  match xs:
    case Nil{}:
      {==}
    case +h <> +t:
      +g = List.reverse.go(&2, F.Frame, t, Nil{})
      %Equal.sym(List<&2, F.Frame>, List.reverse.go(&2, F.Frame, t, [h]), List.append(&2, F.Frame, g, [h]), rev_go(t, [h]))
        : {List.reverse.go(&2, F.Frame, t, h <> acc) == List.append(&2, F.Frame, _, acc) : List<&2, F.Frame>}
      %Equal.sym(List<&2, F.Frame>, List.append(&2, F.Frame, List.append(&2, F.Frame, g, [h]), acc),
          List.append(&2, F.Frame, g, h <> acc), append_assoc(g, [h], acc))
        : {List.reverse.go(&2, F.Frame, t, h <> acc) == _ : List<&2, F.Frame>}
      rev_go(t, h <> acc)

def go_app(xs: List<&2, F.Frame>, ys: List<&2, F.Frame>, acc: List<&2, F.Frame>) ->
  {List.reverse.go(&2, F.Frame, List.append(&2, F.Frame, xs, ys), acc)
    == List.reverse.go(&2, F.Frame, ys, List.reverse.go(&2, F.Frame, xs, acc)) : List<&2, F.Frame>}:
  match xs:
    case Nil{}:
      {==}
    case h <> t:
      go_app(t, ys, h <> acc)

def rev_app(+xs: List<&2, F.Frame>, +ys: List<&2, F.Frame>) ->
  {List.reverse(&2, F.Frame, List.append(&2, F.Frame, xs, ys))
    == List.append(&2, F.Frame, List.reverse(&2, F.Frame, ys), List.reverse(&2, F.Frame, xs)) : List<&2, F.Frame>}:
  %Equal.sym(List<&2, F.Frame>, List.reverse.go(&2, F.Frame, List.append(&2, F.Frame, xs, ys), Nil{}),
      List.reverse.go(&2, F.Frame, ys, List.reverse.go(&2, F.Frame, xs, Nil{})), go_app(xs, ys, Nil{}))
    : {_ == List.append(&2, F.Frame, List.reverse(&2, F.Frame, ys), List.reverse(&2, F.Frame, xs)) : List<&2, F.Frame>}
  rev_go(ys, List.reverse(&2, F.Frame, xs))

def fold_app(xs: List<&2, F.Frame>, ys: List<&2, F.Frame>, s: S.Session) ->
  {S.react_frames(s, List.append(&2, F.Frame, xs, ys)) == S.react_frames(S.react_frames(s, xs), ys) : S.Session}:
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      fold_app(t, ys, S.react(s, W.decode(h)))

def took(q: F.Rx, +dr: List<&2, F.Frame>, +se: S.Session) ->
  {S.receive.go(F.take(q), S.react_frames(se, List.reverse(&2, F.Frame, dr)))
    == S.receive.go(F.take(app(q, dr)), se) : S.Conn}:
  match q:
    case F.Rx{phase, tag, need, w, left, cur, cells, +dq}:
      +rq = List.reverse(&2, F.Frame, dq)
      +rr = List.reverse(&2, F.Frame, dr)
      +lhs = {S.Conn{F.Rx{phase, tag, need, w, left, cur, cells, Nil{}}, S.react_frames(S.react_frames(se, rr), rq)} : S.Conn}
      %Equal.sym(List<&2, F.Frame>, List.reverse(&2, F.Frame, List.append(&2, F.Frame, dq, dr)),
          List.append(&2, F.Frame, rr, rq), rev_app(dq, dr))
        : {lhs == S.Conn{F.Rx{phase, tag, need, w, left, cur, cells, Nil{}}, S.react_frames(se, _)} : S.Conn}
      %Equal.sym(S.Session, S.react_frames(se, List.append(&2, F.Frame, rr, rq)),
          S.react_frames(S.react_frames(se, rr), rq), fold_app(rr, rq, se))
        : {lhs == S.Conn{F.Rx{phase, tag, need, w, left, cur, cells, Nil{}}, _} : S.Conn}
      {==}

def split(r: F.Rx, +b: List<&2, U32>, +se: S.Session) ->
  {S.receive(S.receive.go(F.take(r), se), b) == S.receive.go(F.take(F.feed(r, b)), se) : S.Conn}:
  match r:
    case F.Rx{+phase, +tag, +need, +w, +left, +cur, +cells, +dr}:
      +q0 = {F.Rx{phase, tag, need, w, left, cur, cells, Nil{}} : F.Rx}
      %Equal.sym(F.Rx, F.feed(app(q0, dr), b), app(F.feed(q0, b), dr), feed_app(b, dr, q0))
        : {S.receive(S.receive.go(F.take(F.Rx{phase, tag, need, w, left, cur, cells, dr}), se), b)
          == S.receive.go(F.take(_), se) : S.Conn}
      took(F.feed(q0, b), dr, se)

def Laws.receive_split(c, a, b):
  match c:
    case S.Conn{+rx, +se}:
      %Laws.feed_split(a, b, rx) : {S.receive(S.receive.go(F.take(F.feed(rx, a)), se), b) == S.receive.go(F.take(_), se) : S.Conn}
      split(F.feed(rx, a), b, se)

# ---- decoding in lanes

# decode_keeps_order: merge undoes deal (base0, by swap), and a level of
# lanes decodes as no lanes once each half does (up), by induction on depth.

def swap(t: List<&2, List<&2, S.Reply>>, m: List<&2, List<&2, S.Reply>>, +x: List<&2, S.Reply>) ->
  {S.merge(x <> t, m) == x <> S.merge(m, t) : List<&2, List<&2, S.Reply>>}:
  match t m:
    case Nil{} Nil{}:
      {==}
    case z <> v Nil{}:
      {==}
    case Nil{} y <> Nil{}:
      {==}
    case Nil{} y <> w <> q:
      {==}
    case +z <> v +y <> u:
      %swap(v, u, z) : {x <> y <> S.merge(z <> v, u) == x <> y <> _ : List<&2, List<&2, S.Reply>>}
      {==}

def cons0(+c: List<&2, S.Item>, +rest: List<&2, List<&2, S.Item>>,
  p: List<&2, List<&2, S.Item>> & List<&2, List<&2, S.Item>>,
  ih: {S.decode(0n, p) == S.chunks(rest) : List<&2, List<&2, S.Reply>>}) ->
  {S.decode(0n, S.deal.cons(c, p)) == S.chunks(c <> rest) : List<&2, List<&2, S.Reply>>}:
  match p:
    case (+a, +b):
      +x = S.items(List.reverse(&2, S.Item, c))
      %Equal.sym(List<&2, List<&2, S.Reply>>, S.merge(x <> S.chunks(b), S.chunks(a)),
          x <> S.merge(S.chunks(a), S.chunks(b)), swap(S.chunks(b), S.chunks(a), x))
        : {_ == x <> S.chunks(rest) : List<&2, List<&2, S.Reply>>}
      %Equal.sym(List<&2, List<&2, S.Reply>>, S.merge(S.chunks(a), S.chunks(b)), S.chunks(rest), ih)
        : {x <> _ == x <> S.chunks(rest) : List<&2, List<&2, S.Reply>>}
      {==}

def base0(cs: List<&2, List<&2, S.Item>>) ->
  {S.decode(0n, S.deal(cs)) == S.chunks(cs) : List<&2, List<&2, S.Reply>>}:
  match cs:
    case Nil{}:
      {==}
    case +c <> +rest:
      cons0(c, rest, S.deal(rest), base0(rest))

# One level of lanes decodes as no lanes, given that each half does.
def up(+d: Nat, p: List<&2, List<&2, S.Item>> & List<&2, List<&2, S.Item>>,
  il: {S.decode(d, S.deal(Pair.fst(List<&2, List<&2, S.Item>>, List<&2, List<&2, S.Item>>, p)))
    == S.chunks(Pair.fst(List<&2, List<&2, S.Item>>, List<&2, List<&2, S.Item>>, p)) : List<&2, List<&2, S.Reply>>},
  ir: {S.decode(d, S.deal(Pair.snd(List<&2, List<&2, S.Item>>, List<&2, List<&2, S.Item>>, p)))
    == S.chunks(Pair.snd(List<&2, List<&2, S.Item>>, List<&2, List<&2, S.Item>>, p)) : List<&2, List<&2, S.Reply>>}) ->
  {S.decode(1n+d, p) == S.decode(0n, p) : List<&2, List<&2, S.Reply>>}:
  match p:
    case (+l, +r):
      %il : {S.merge(S.decode(d, S.deal(l)), S.decode(d, S.deal(r))) == S.merge(_, S.chunks(r)) : List<&2, List<&2, S.Reply>>}
      %ir : {S.merge(S.decode(d, S.deal(l)), S.decode(d, S.deal(r))) == S.merge(S.decode(d, S.deal(l)), _) : List<&2, List<&2, S.Reply>>}
      {==}

def Laws.decode_keeps_order(depth, cs):
  match depth:
    case 0n:
      base0(cs)
    case 1n+(+d):
      Equal.trans(List<&2, List<&2, S.Reply>>, S.decode(1n+d, S.deal(cs)), S.decode(0n, S.deal(cs)), S.chunks(cs),
        up(d, S.deal(cs), Laws.decode_keeps_order(d, Pair.fst(List<&2, List<&2, S.Item>>, List<&2, List<&2, S.Item>>, S.deal(cs))),
          Laws.decode_keeps_order(d, Pair.snd(List<&2, List<&2, S.Item>>, List<&2, List<&2, S.Item>>, S.deal(cs)))), base0(cs))

# ---- equality of bytes, and SCRAM

# B.eq is sound (bytes_eq: down to U32's 32 bits) and reflexive
# (bytes_refl), so SCRAM's check accepts exactly the expected signature.
# The *_only types refute a clash such as LT == EQ.

def eq_only(c: Cmp) -> Type:
  match c:
    case EQ{}:
      Unit
    case _:
      Empty

def lt_eq(e: {LT{} == EQ{} : Cmp}) -> Empty:
  %Equal.sym(Cmp, LT{}, EQ{}, e) : eq_only(_)
  Unit{}

def gt_eq(e: {GT{} == EQ{} : Cmp}) -> Empty:
  %Equal.sym(Cmp, GT{}, EQ{}, e) : eq_only(_)
  Unit{}

def fin_same(+x: Bool, t: Cmp, e: {Word.cmp.fin(x, x, t) == EQ{} : Cmp}) -> {t == EQ{} : Cmp}:
  match t:
    case LT{}:
      Empty.absurd({LT{} == EQ{} : Cmp}, lt_eq(e))
    case EQ{}:
      {==}
    case GT{}:
      Empty.absurd({GT{} == EQ{} : Cmp}, gt_eq(e))

def fin_differ(t: Cmp, e: {Word.cmp.fin(True{}, False{}, t) == EQ{} : Cmp}) -> Empty:
  match t:
    case LT{}:
      lt_eq(e)
    case EQ{}:
      gt_eq(e)
    case GT{}:
      gt_eq(e)

def fin_differ2(t: Cmp, e: {Word.cmp.fin(False{}, True{}, t) == EQ{} : Cmp}) -> Empty:
  match t:
    case LT{}:
      lt_eq(e)
    case EQ{}:
      lt_eq(e)
    case GT{}:
      gt_eq(e)

# Words that compare equal are equal.
def word_eq(n: Nat, a: Word(n), b: Word(n), e: {Word.cmp(n, a, b) == EQ{} : Cmp}) -> {a == b : Word(n)}:
  match n:
    case 0n:
      match a b:
        case WNil{} WNil{}:
          {==}
    case 1n+(+p):
      match a b:
        case WCon{True{}, +at} WCon{True{}, +bt}:
          %word_eq(p, at, bt, fin_same(True{}, Word.cmp(p, at, bt), e)) : {WCon{True{}, at} == WCon{True{}, _} : Word(1n+p)}
          {==}
        case WCon{False{}, +at} WCon{False{}, +bt}:
          %word_eq(p, at, bt, fin_same(False{}, Word.cmp(p, at, bt), e)) : {WCon{False{}, at} == WCon{False{}, _} : Word(1n+p)}
          {==}
        case WCon{True{}, at} WCon{False{}, bt}:
          Empty.absurd({WCon{True{}, at} == WCon{False{}, bt} : Word(1n+p)}, fin_differ(Word.cmp(p, at, bt), e))
        case WCon{False{}, at} WCon{True{}, bt}:
          Empty.absurd({WCon{False{}, at} == WCon{True{}, bt} : Word(1n+p)}, fin_differ2(Word.cmp(p, at, bt), e))

def true_only(b: Bool) -> Type:
  match b:
    case True{}:
      Unit
    case False{}:
      Empty

def false_true(e: {False{} == True{} : Bool}) -> Empty:
  %Equal.sym(Bool, False{}, True{}, e) : true_only(_)
  Unit{}

def cmp_eq(c: Cmp, e: {Cmp.is_eq(c) == True{} : Bool}) -> {c == EQ{} : Cmp}:
  match c:
    case LT{}:
      Empty.absurd({LT{} == EQ{} : Cmp}, false_true(e))
    case EQ{}:
      {==}
    case GT{}:
      Empty.absurd({GT{} == EQ{} : Cmp}, false_true(e))

# U32s that is_eq calls equal are equal.
def u32_eq(a: U32, b: U32, e: {U32.is_eq(a, b) == True{} : Bool}) -> {a == b : U32}:
  match a b:
    case U32{+x} U32{+y}:
      %word_eq(32n, x, y, cmp_eq(Word.cmp(32n, x, y), e)) : {U32{x} == U32{_} : U32}
      {==}

def and_l(p: Bool, q: Bool, e: {Bool.and(p, q) == True{} : Bool}) -> {p == True{} : Bool}:
  match p:
    case True{}:
      {==}
    case False{}:
      Empty.absurd({False{} == True{} : Bool}, false_true(e))

def and_r(p: Bool, q: Bool, e: {Bool.and(p, q) == True{} : Bool}) -> {q == True{} : Bool}:
  match p:
    case True{}:
      e
    case False{}:
      Empty.absurd({q == True{} : Bool}, false_true(e))

# Byte strings that B.eq calls equal are equal.
def bytes_eq(a: List<&2, U32>, b: List<&2, U32>, +e: {B.eq(a, b) == True{} : Bool}) -> {a == b : List<&2, U32>}:
  match a b:
    case Nil{} Nil{}:
      {==}
    case +x <> +xs +y <> +ys:
      %u32_eq(x, y, and_l(U32.is_eq(x, y), B.eq(xs, ys), e)) : {x <> xs == _ <> ys : List<&2, U32>}
      %bytes_eq(xs, ys, and_r(U32.is_eq(x, y), B.eq(xs, ys), e)) : {x <> xs == x <> _ : List<&2, U32>}
      {==}
    case Nil{} y <> ys:
      Empty.absurd({Nil{} == y <> ys : List<&2, U32>}, false_true(e))
    case x <> xs Nil{}:
      Empty.absurd({x <> xs == Nil{} : List<&2, U32>}, false_true(e))

def send_only(a: A.Answer) -> Type:
  match a:
    case A.Answer.Send{l, b}:
      Unit
    case A.Answer.Fail{m}:
      Empty

def fail_send(m: String, l: A.Login, b: List<&2, U32>, e: {A.Answer.Fail{m} == A.Answer.Send{l, b} : A.Answer}) -> Empty:
  %Equal.sym(A.Answer, A.Answer.Fail{m}, A.Answer.Send{l, b}, e) : send_only(_)
  Unit{}

def verified_ok(same: Bool, e: {A.verified(same) == A.Answer.Send{A.Login.Done{}, Nil{}} : A.Answer}) ->
  {same == True{} : Bool}:
  match same:
    case True{}:
      {==}
    case False{}:
      Empty.absurd({False{} == True{} : Bool}, fail_send("the server's SCRAM signature is wrong", A.Login.Done{}, Nil{}, e))

def Laws.scram_signature_checked(data, sig, e):
  bytes_eq(A.scram.signature(A.attrs(data)), sig, verified_ok(B.eq(A.scram.signature(A.attrs(data)), sig), e))

def word_refl(n: Nat, a: Word(n)) -> {Word.cmp(n, a, a) == EQ{} : Cmp}:
  match n:
    case 0n:
      {==}
    case 1n+(+p):
      match a:
        case WCon{True{}, +t}:
          %Equal.sym(Cmp, Word.cmp(p, t, t), EQ{}, word_refl(p, t)) : {Word.cmp.fin(True{}, True{}, _) == EQ{} : Cmp}
          {==}
        case WCon{False{}, +t}:
          %Equal.sym(Cmp, Word.cmp(p, t, t), EQ{}, word_refl(p, t)) : {Word.cmp.fin(False{}, False{}, _) == EQ{} : Cmp}
          {==}

def bytes_refl(xs: List<&2, U32>) -> {B.eq(xs, xs) == True{} : Bool}:
  match xs:
    case Nil{}:
      {==}
    case U32{+w} <> +t:
      %Equal.sym(Cmp, Word.cmp(32n, w, w), EQ{}, word_refl(32n, w)) : {Bool.and(Cmp.is_eq(_), B.eq(t, t)) == True{} : Bool}
      %Equal.sym(Bool, B.eq(t, t), True{}, bytes_refl(t)) : {Bool.and(True{}, _) == True{} : Bool}
      {==}

def Laws.scram_signature_accepted(data):
  %Equal.sym(Bool, B.eq(A.scram.signature(A.attrs(data)), A.scram.signature(A.attrs(data))), True{}, bytes_refl(A.scram.signature(A.attrs(data)))) : {A.verified(_) == A.Answer.Send{A.Login.Done{}, Nil{}} : A.Answer}
  {==}

# ---- the session

def Laws.refused_login_fails(code, data, login, m, e, queue, run, key, fields, out, log):
  %Equal.sym(A.Answer, A.answer(code, data, login), A.Answer.Fail{m}, e)
    : {S.auth(S.Session{0, login, queue, run, key, fields, out, log}, _)
      == S.Session{3, A.Login.Done{}, queue, run, key, fields, out, S.push(log, S.Item.Reply{S.Reply.Refused{m}})}
      : S.Session}
  {==}

def Laws.failed_inert(login, queue, run, key, fields, out, log, msg):
  {==}

def Laws.scram_not_skipped(data, sig, password, nonce):
  {==}

def Laws.error_syncs(login, queue, simple, fetch, timeout, stopped, key, fields, out, log, sev, code, m):
  {==}

def Laws.error_after_sync(login, queue, simple, fetch, timeout, stopped, key, fields, out, log, sev, code, m):
  {==}

def Laws.batches_continue(login, queue, simple, fetch, timeout, synced, key, fields, out, log):
  {==}

def Laws.cancelled_batches_close(login, queue, simple, fetch, timeout, synced, key, fields, out, log):
  {==}

def Laws.cancel_once(rx, phase, login, queue, simple, fetch, timeout, synced, key, fields, out, log):
  {==}

def Laws.cancel_bounded(rx, phase, login, queue, simple, fetch, timeout, synced, key, fields, out, log):
  {==}

def Laws.copy_in_refused(login, queue, simple, fetch, timeout, synced, stopped, key, fields, out, log):
  {==}

# ---- vectors: both sides compute to the same term.

def Laws.feed_frames():
  {==}

def Laws.utf8_sample():
  {==}

def Laws.query_bytes():
  {==}

def Laws.ready_split():
  {==}

def Laws.error_fields():
  {==}

def Laws.typed_row():
  {==}

def Laws.failed_login_stays_failed():
  {==}

def Laws.extended_bytes():
  {==}

def Laws.cancel_bytes():
  {==}

def Laws.copy_in_bytes():
  {==}

def Laws.forged_scram_refused():
  {==}
