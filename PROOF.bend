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

# feed_split and receive_split: at the end of this file, after the lemmas
# on Bool they use.

# ---- Base's Bytes

def Laws.bytes_slice(b, o, n):
  match b:
    case Bytes{data}:
      {==}

def Laws.bytes_concat(a, b):
  match a b:
    case Bytes{xs} Bytes{ys}:
      {==}

def Laws.bytes_copy(b):
  {==}

def length_drop(xs: List<&2, U32>, o: Nat) ->
  {List.length(&2, U32, List.drop(&2, U32, xs, o)) == Nat.sub(List.length(&2, U32, xs), o) : Nat}:
  match xs o:
    case Nil{} _:
      {==}
    case h <> t 0n:
      {==}
    case h <> t 1n+p:
      length_drop(t, p)

def length_take(xs: List<&2, U32>, n: Nat) ->
  {List.length(&2, U32, List.take(&2, U32, xs, n)) == Nat.min(n, List.length(&2, U32, xs)) : Nat}:
  match xs n:
    case Nil{} 0n:
      {==}
    case Nil{} 1n+p:
      {==}
    case h <> t 0n:
      {==}
    case h <> t 1n+p:
      %length_take(t, p) : {1n+List.length(&2, U32, List.take(&2, U32, t, p)) == 1n+_ : Nat}
      {==}

def Laws.bytes_slice_length(b, o, n):
  match b:
    case Bytes{+data}:
      +d = List.drop(&2, U32, data, o)
      %length_drop(data, o) : {List.length(&2, U32, List.take(&2, U32, d, n)) == Nat.min(n, _) : Nat}
      length_take(d, n)

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

# ---- the framer and the connection: how TCP cuts the stream never
# matters (feed_split, receive_split)
#
# The framer cuts whole messages off the front of its bytes. A message
# whole in xs is the same message in xs ++ ys, and what is left after it
# is the rest of xs then ys (k5), so cutting xs and then the rest ++ ys is
# cutting xs ++ ys, given fuel enough (fi: any fuel past the length gives
# the same). In Bytes' theory every step is a list operation; lemmas on
# lists and Nat first.

def nf_true(e: {True{} == False{} : Bool}) -> Empty:
  false_true(Equal.sym(Bool, True{}, False{}, e))

def pos_only(n: Nat) -> Type:
  match n:
    case 0n:
      Empty
    case 1n+p:
      Unit

def succ_zero(p: Nat, e: {1n+p == 0n : Nat}) -> Empty:
  %e : pos_only(_)
  Unit{}

# a <= b, as Nat.sub(a, b) == 0.
def le_refl(a: Nat) -> {Nat.sub(a, a) == 0n : Nat}:
  match a:
    case 0n:
      {==}
    case 1n+p:
      le_refl(p)

def le_succ(a: Nat, b: Nat, e: {Nat.sub(a, b) == 0n : Nat}) -> {Nat.sub(a, 1n+b) == 0n : Nat}:
  match a b:
    case 0n _:
      {==}
    case 1n+(+p) 0n:
      Empty.absurd({Nat.sub(1n+p, 1n) == 0n : Nat}, succ_zero(p, e))
    case 1n+p 1n+q:
      le_succ(p, q, e)

def le_trans(a: Nat, b: Nat, c: Nat, e1: {Nat.sub(a, b) == 0n : Nat}, e2: {Nat.sub(b, c) == 0n : Nat}) ->
  {Nat.sub(a, c) == 0n : Nat}:
  match a b c:
    case 0n _ _:
      {==}
    case 1n+(+p) 0n _:
      Empty.absurd({Nat.sub(1n+p, c) == 0n : Nat}, succ_zero(p, e1))
    case 1n+(+p) 1n+(+q) 0n:
      Empty.absurd({Nat.sub(1n+p, 0n) == 0n : Nat}, succ_zero(q, e2))
    case 1n+p 1n+q 1n+r:
      le_trans(p, q, r, e1, e2)

def le4(+a: Nat) -> {Nat.sub(a, 4n+a) == 0n : Nat}:
  le_succ(a, 3n+a, le_succ(a, 2n+a, le_succ(a, 1n+a, le_succ(a, a, le_refl(a)))))

def drop_le(r: List<&2, U32>, w: Nat) ->
  {Nat.sub(List.length(&2, U32, List.drop(&2, U32, r, w)), List.length(&2, U32, r)) == 0n : Nat}:
  match r w:
    case Nil{} _:
      {==}
    case h <> +t 0n:
      le_refl(List.length(&2, U32, t))
    case h <> +t 1n+(+p):
      le_succ(List.length(&2, U32, List.drop(&2, U32, t, p)), List.length(&2, U32, t), drop_le(t, p))

def drop_app_le(r: List<&2, U32>, w: Nat, +ys: List<&2, U32>) ->
  {Nat.sub(List.length(&2, U32, List.append(&2, U32, List.drop(&2, U32, r, w), ys)),
    List.length(&2, U32, List.append(&2, U32, r, ys))) == 0n : Nat}:
  match r w:
    case Nil{} _:
      le_refl(List.length(&2, U32, ys))
    case h <> +t 0n:
      le_refl(List.length(&2, U32, List.append(&2, U32, t, ys)))
    case h <> +t 1n+(+p):
      le_succ(List.length(&2, U32, List.append(&2, U32, List.drop(&2, U32, t, p), ys)),
        List.length(&2, U32, List.append(&2, U32, t, ys)), drop_app_le(t, p, ys))

# What is left after a message fits the fuel left.
def fuel_drop(+r: List<&2, U32>, +w: Nat, +q: Nat, e: {Nat.sub(4n+List.length(&2, U32, r), q) == 0n : Nat}) ->
  {Nat.sub(List.length(&2, U32, List.drop(&2, U32, r, w)), q) == 0n : Nat}:
  le_trans(List.length(&2, U32, List.drop(&2, U32, r, w)), List.length(&2, U32, r), q, drop_le(r, w),
    le_trans(List.length(&2, U32, r), 4n+List.length(&2, U32, r), q, le4(List.length(&2, U32, r)), e))

# A prefix long enough reads the same with anything after it.
def take_app(r: List<&2, U32>, w: Nat, +ys: List<&2, U32>,
  e: {Nat.is_lt(List.length(&2, U32, r), w) == False{} : Bool}) ->
  {List.take(&2, U32, List.append(&2, U32, r, ys), w) == List.take(&2, U32, r, w) : List<&2, U32>}:
  match r w:
    case Nil{} 0n:
      match ys:
        case Nil{}:
          {==}
        case h <> t:
          {==}
    case Nil{} 1n+p:
      Empty.absurd({List.take(&2, U32, ys, 1n+p) == Nil{} : List<&2, U32>}, nf_true(e))
    case h <> t 0n:
      {==}
    case +h <> t 1n+p:
      %take_app(t, p, ys, e) : {h <> List.take(&2, U32, List.append(&2, U32, t, ys), p) == h <> _ : List<&2, U32>}
      {==}

def drop_app(r: List<&2, U32>, w: Nat, +ys: List<&2, U32>,
  e: {Nat.is_lt(List.length(&2, U32, r), w) == False{} : Bool}) ->
  {List.drop(&2, U32, List.append(&2, U32, r, ys), w)
    == List.append(&2, U32, List.drop(&2, U32, r, w), ys) : List<&2, U32>}:
  match r w:
    case Nil{} 0n:
      match ys:
        case Nil{}:
          {==}
        case h <> t:
          {==}
    case Nil{} 1n+p:
      Empty.absurd({List.drop(&2, U32, ys, 1n+p) == ys : List<&2, U32>}, nf_true(e))
    case h <> t 0n:
      {==}
    case h <> t 1n+p:
      drop_app(t, p, ys, e)

def lt_app(r: List<&2, U32>, w: Nat, +ys: List<&2, U32>,
  e: {Nat.is_lt(List.length(&2, U32, r), w) == False{} : Bool}) ->
  {Nat.is_lt(List.length(&2, U32, List.append(&2, U32, r, ys)), w) == False{} : Bool}:
  match r w:
    case Nil{} 0n:
      match ys:
        case Nil{}:
          {==}
        case h <> t:
          {==}
    case Nil{} 1n+p:
      Empty.absurd({Nat.is_lt(List.length(&2, U32, ys), 1n+p) == False{} : Bool}, nf_true(e))
    case h <> t 0n:
      {==}
    case h <> t 1n+p:
      lt_app(t, p, ys, e)

# A message's body length, read from bytes 1 to 4, and the message.
def wd(x1: U32, x2: U32, x3: U32, x4: U32) -> Nat:
  Nat.sub(U32.to_nat(Bytes.be32(Bytes{[0, x1, x2, x3, x4]}, 1n)), 4n)

def msg(+x0: U32, r: List<&2, U32>, w: Nat) -> F.Frame:
  F.message(U32.is_eq(x0, 68), x0, Bytes{List.take(&2, U32, List.drop(&2, U32, r, 0n), w)})

# Fuel past the length is fuel enough: any two such cut the same.
def fi5(c: Bool, +x0: U32, +x1: U32, +x2: U32, +x3: U32, +x4: U32, +r: List<&2, U32>, +w: Nat,
  q: Nat, q2: Nat, +d: List<&2, F.Frame>,
  ih: {F.cut.go(q, Bytes{List.drop(&2, U32, r, w)}, F.step(Bytes{List.drop(&2, U32, r, w)}), msg(x0, r, w) <> d)
    == F.cut.go(q2, Bytes{List.drop(&2, U32, r, w)}, F.step(Bytes{List.drop(&2, U32, r, w)}), msg(x0, r, w) <> d) : F.Rx}) ->
  {F.cut.go(1n+q, Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> r}, F.step.whole(c, Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> r}, w), d)
    == F.cut.go(1n+q2, Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> r}, F.step.whole(c, Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> r}, w), d) : F.Rx}:
  match c:
    case True{}:
      {==}
    case False{}:
      ih

def fi(j: Nat, k: Nat, zs: List<&2, U32>, +d: List<&2, F.Frame>,
  hj: {Nat.sub(List.length(&2, U32, zs), j) == 0n : Nat},
  hk: {Nat.sub(List.length(&2, U32, zs), k) == 0n : Nat}) ->
  {F.cut.go(j, Bytes{zs}, F.step(Bytes{zs}), d) == F.cut.go(k, Bytes{zs}, F.step(Bytes{zs}), d) : F.Rx}:
  match j k zs:
    case 1n+(+q) 1n+(+q2) +x0 <> +x1 <> +x2 <> +x3 <> +x4 <> +r:
      +w = wd(x1, x2, x3, x4)
      fi5(Nat.is_lt(List.length(&2, U32, r), w), x0, x1, x2, x3, x4, r, w, q, q2, d,
        fi(q, q2, List.drop(&2, U32, r, w), msg(x0, r, w) <> d, fuel_drop(r, w, q, hj), fuel_drop(r, w, q2, hk)))
    case 0n 1n+(+q2) +x0 <> +x1 <> +x2 <> +x3 <> +x4 <> +r:
      +zs = {x0 <> x1 <> x2 <> x3 <> x4 <> r : List<&2, U32>}
      Empty.absurd({F.cut.go(0n, Bytes{zs}, F.step(Bytes{zs}), d) == F.cut.go(1n+q2, Bytes{zs}, F.step(Bytes{zs}), d) : F.Rx},
        succ_zero(4n+List.length(&2, U32, r), hj))
    case 1n+(+q) 0n +x0 <> +x1 <> +x2 <> +x3 <> +x4 <> +r:
      +zs = {x0 <> x1 <> x2 <> x3 <> x4 <> r : List<&2, U32>}
      Empty.absurd({F.cut.go(1n+q, Bytes{zs}, F.step(Bytes{zs}), d) == F.cut.go(0n, Bytes{zs}, F.step(Bytes{zs}), d) : F.Rx},
        succ_zero(4n+List.length(&2, U32, r), hk))
    case 0n 0n _:
      {==}
    case _ _ Nil{}:
      {==}
    case _ _ x0 <> Nil{}:
      {==}
    case _ _ x0 <> x1 <> Nil{}:
      {==}
    case _ _ x0 <> x1 <> x2 <> Nil{}:
      {==}
    case _ _ x0 <> x1 <> x2 <> x3 <> Nil{}:
      {==}

# The first w bytes after a message's header read the same with anything
# after them.
def tk(r: List<&2, U32>, w: Nat, +ys: List<&2, U32>,
  e: {Nat.is_lt(List.length(&2, U32, r), w) == False{} : Bool}) ->
  {List.take(&2, U32, List.drop(&2, U32, List.append(&2, U32, r, ys), 0n), w)
    == List.take(&2, U32, List.drop(&2, U32, r, 0n), w) : List<&2, U32>}:
  match r:
    case Nil{}:
      match ys:
        case Nil{}:
          take_app(Nil{}, w, Nil{}, e)
        case +y <> +yt:
          take_app(Nil{}, w, y <> yt, e)
    case h <> t:
      take_app(h <> t, w, ys, e)

# Cutting with enough fuel, then the rest ++ ys, is cutting zs ++ ys.
def k5b(c2: Bool, l: {c2 == False{} : Bool},
  +x0: U32, +x1: U32, +x2: U32, +x3: U32, +x4: U32, +r: List<&2, U32>, +ys: List<&2, U32>, +w: Nat,
  +e: {Nat.is_lt(List.length(&2, U32, r), w) == False{} : Bool},
  +q: Nat, +d: List<&2, F.Frame>,
  ih: {F.feed_bytes(F.cut.go(q, Bytes{List.drop(&2, U32, r, w)}, F.step(Bytes{List.drop(&2, U32, r, w)}), msg(x0, r, w) <> d), Bytes{ys})
    == F.cut(Bytes{List.append(&2, U32, List.drop(&2, U32, r, w), ys)}, msg(x0, r, w) <> d) : F.Rx}) ->
  {F.feed_bytes(F.cut.go(q, Bytes{List.drop(&2, U32, r, w)}, F.step(Bytes{List.drop(&2, U32, r, w)}), msg(x0, r, w) <> d), Bytes{ys})
    == F.cut.go(1n+(4n+List.length(&2, U32, List.append(&2, U32, r, ys))),
      Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> List.append(&2, U32, r, ys)},
      F.step.whole(c2, Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> List.append(&2, U32, r, ys)}, w), d) : F.Rx}:
  match c2:
    case True{}:
      Empty.absurd({F.feed_bytes(F.cut.go(q, Bytes{List.drop(&2, U32, r, w)}, F.step(Bytes{List.drop(&2, U32, r, w)}), msg(x0, r, w) <> d), Bytes{ys})
        == F.cut.go(1n+(4n+List.length(&2, U32, List.append(&2, U32, r, ys))),
          Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> List.append(&2, U32, r, ys)},
          F.step.whole(True{}, Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> List.append(&2, U32, r, ys)}, w), d) : F.Rx}, nf_true(l))
    case False{}:
      +ry = List.append(&2, U32, r, ys)
      +dr = List.drop(&2, U32, r, w)
      +rest = List.append(&2, U32, dr, ys)
      +lhs = F.feed_bytes(F.cut.go(q, Bytes{dr}, F.step(Bytes{dr}), msg(x0, r, w) <> d), Bytes{ys})
      +n = {4n+List.length(&2, U32, ry) : Nat}
      %Equal.sym(List<&2, U32>, List.take(&2, U32, List.drop(&2, U32, ry, 0n), w),
          List.take(&2, U32, List.drop(&2, U32, r, 0n), w), tk(r, w, ys, e))
        : {lhs == F.cut.go(n, Bytes{List.drop(&2, U32, ry, w)}, F.step(Bytes{List.drop(&2, U32, ry, w)}),
            F.message(U32.is_eq(x0, 68), x0, Bytes{_}) <> d) : F.Rx}
      %Equal.sym(List<&2, U32>, List.drop(&2, U32, ry, w), rest, drop_app(r, w, ys, e))
        : {lhs == F.cut.go(n, Bytes{_}, F.step(Bytes{_}), msg(x0, r, w) <> d) : F.Rx}
      %Equal.sym(F.Rx, lhs, F.cut(Bytes{rest}, msg(x0, r, w) <> d), ih)
        : {_ == F.cut.go(n, Bytes{rest}, F.step(Bytes{rest}), msg(x0, r, w) <> d) : F.Rx}
      fi(List.length(&2, U32, rest), n, rest, msg(x0, r, w) <> d, le_refl(List.length(&2, U32, rest)),
        le_trans(List.length(&2, U32, rest), List.length(&2, U32, ry), n, drop_app_le(r, w, ys), le4(List.length(&2, U32, ry))))

def k5(c: Bool,
  +x0: U32, +x1: U32, +x2: U32, +x3: U32, +x4: U32, +r: List<&2, U32>, +ys: List<&2, U32>,
  +e: {Nat.is_lt(List.length(&2, U32, r), wd(x1, x2, x3, x4)) == c : Bool},
  +q: Nat, +d: List<&2, F.Frame>,
  ih: {F.feed_bytes(F.cut.go(q, Bytes{List.drop(&2, U32, r, wd(x1, x2, x3, x4))}, F.step(Bytes{List.drop(&2, U32, r, wd(x1, x2, x3, x4))}), msg(x0, r, wd(x1, x2, x3, x4)) <> d), Bytes{ys})
    == F.cut(Bytes{List.append(&2, U32, List.drop(&2, U32, r, wd(x1, x2, x3, x4)), ys)}, msg(x0, r, wd(x1, x2, x3, x4)) <> d) : F.Rx}) ->
  {F.feed_bytes(F.cut.go(1n+q, Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> r}, F.step.whole(c, Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> r}, wd(x1, x2, x3, x4)), d), Bytes{ys})
    == F.cut(Bytes{x0 <> x1 <> x2 <> x3 <> x4 <> List.append(&2, U32, r, ys)}, d) : F.Rx}:
  match c:
    case True{}:
      {==}
    case False{}:
      +w = wd(x1, x2, x3, x4)
      k5b(Nat.is_lt(List.length(&2, U32, List.append(&2, U32, r, ys)), w), lt_app(r, w, ys, e),
        x0, x1, x2, x3, x4, r, ys, w, e, q, d, ih)

def K(j: Nat, zs: List<&2, U32>, +ys: List<&2, U32>, +d: List<&2, F.Frame>,
  hj: {Nat.sub(List.length(&2, U32, zs), j) == 0n : Nat}) ->
  {F.feed_bytes(F.cut.go(j, Bytes{zs}, F.step(Bytes{zs}), d), Bytes{ys}) == F.cut(Bytes{List.append(&2, U32, zs, ys)}, d) : F.Rx}:
  match j zs:
    case 1n+(+q) +x0 <> +x1 <> +x2 <> +x3 <> +x4 <> +r:
      +w = wd(x1, x2, x3, x4)
      k5(Nat.is_lt(List.length(&2, U32, r), w), x0, x1, x2, x3, x4, r, ys, {==}, q, d,
        K(q, List.drop(&2, U32, r, w), ys, msg(x0, r, w) <> d, fuel_drop(r, w, q, hj)))
    case 0n +x0 <> +x1 <> +x2 <> +x3 <> +x4 <> +r:
      +zs = {x0 <> x1 <> x2 <> x3 <> x4 <> r : List<&2, U32>}
      Empty.absurd({F.feed_bytes(F.cut.go(0n, Bytes{zs}, F.step(Bytes{zs}), d), Bytes{ys}) == F.cut(Bytes{List.append(&2, U32, zs, ys)}, d) : F.Rx},
        succ_zero(4n+List.length(&2, U32, r), hj))
    case _ Nil{}:
      {==}
    case _ x0 <> Nil{}:
      {==}
    case _ x0 <> x1 <> Nil{}:
      {==}
    case _ x0 <> x1 <> x2 <> Nil{}:
      {==}
    case _ x0 <> x1 <> x2 <> x3 <> Nil{}:
      {==}

def mask_app(xs: List<&2, U32>, +ys: List<&2, U32>) ->
  {Bytes.mask(List.append(&2, U32, xs, ys)) == List.append(&2, U32, Bytes.mask(xs), Bytes.mask(ys)) : List<&2, U32>}:
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      %mask_app(t, ys) : {(h .&. 255 : U32) <> Bytes.mask(List.append(&2, U32, t, ys)) == (h .&. 255 : U32) <> _ : List<&2, U32>}
      {==}

def u_assoc(xs: List<&2, U32>, +ys: List<&2, U32>, +zs: List<&2, U32>) ->
  {List.append(&2, U32, List.append(&2, U32, xs, ys), zs)
    == List.append(&2, U32, xs, List.append(&2, U32, ys, zs)) : List<&2, U32>}:
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      %u_assoc(t, ys, zs) : {h <> List.append(&2, U32, List.append(&2, U32, t, ys), zs) == h <> _ : List<&2, U32>}
      {==}

def Laws.feed_split(a, b, rx):
  match rx:
    case F.Rx{+rest, +done}:
      match rest:
        case Bytes{+zs}:
          +ma = Bytes.mask(a)
          +mb = Bytes.mask(b)
          +za = List.append(&2, U32, zs, ma)
          %Equal.sym(List<&2, U32>, Bytes.mask(List.append(&2, U32, a, b)), List.append(&2, U32, ma, mb), mask_app(a, b))
            : {F.feed(F.feed(F.Rx{Bytes{zs}, done}, a), b) == F.cut(Bytes{List.append(&2, U32, zs, _)}, done) : F.Rx}
          %u_assoc(zs, ma, mb) : {F.feed(F.feed(F.Rx{Bytes{zs}, done}, a), b) == F.cut(Bytes{_}, done) : F.Rx}
          K(List.length(&2, U32, za), za, mb, done, le_refl(List.length(&2, U32, za)))

# receive_split: the framer only ever puts frames in front of those it
# holds (cut_app), so frames handed over after one read are those it would
# hold after both; then reverse and fold over an append. As on main.

# rx with d after the frames it holds.
def app(rx: F.Rx, d: List<&2, F.Frame>) -> F.Rx:
  match rx:
    case F.Rx{rest, done}:
      F.Rx{rest, List.append(&2, F.Frame, done, d)}

def cut_app(j: Nat, +b: Bytes, st: F.Step, +done: List<&2, F.Frame>, +d: List<&2, F.Frame>) ->
  {F.cut.go(j, b, st, List.append(&2, F.Frame, done, d)) == app(F.cut.go(j, b, st, done), d) : F.Rx}:
  match j st:
    case _ F.Step.Stop{}:
      {==}
    case 0n F.Step.Frame{f, size}:
      {==}
    case 1n+q F.Step.Frame{+f, +size}:
      +rest = Bytes.drop(b, size)
      cut_app(q, rest, F.step(rest), f <> done, d)

def feed_app(b: List<&2, U32>, +d: List<&2, F.Frame>, +rx: F.Rx) ->
  {F.feed(app(rx, d), b) == app(F.feed(rx, b), d) : F.Rx}:
  match rx:
    case F.Rx{+rest, +done}:
      +c = Bytes.concat(rest, Bytes.of_list(b))
      cut_app(Bytes.length(c), c, F.step(c), done, d)

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
    case F.Rx{rest, +dq}:
      +rq = List.reverse(&2, F.Frame, dq)
      +rr = List.reverse(&2, F.Frame, dr)
      +lhs = {S.Conn{F.Rx{rest, Nil{}}, S.react_frames(S.react_frames(se, rr), rq)} : S.Conn}
      %Equal.sym(List<&2, F.Frame>, List.reverse(&2, F.Frame, List.append(&2, F.Frame, dq, dr)),
          List.append(&2, F.Frame, rr, rq), rev_app(dq, dr))
        : {lhs == S.Conn{F.Rx{rest, Nil{}}, S.react_frames(se, _)} : S.Conn}
      %Equal.sym(S.Session, S.react_frames(se, List.append(&2, F.Frame, rr, rq)),
          S.react_frames(S.react_frames(se, rr), rq), fold_app(rr, rq, se))
        : {lhs == S.Conn{F.Rx{rest, Nil{}}, _} : S.Conn}
      {==}

def split(r: F.Rx, +b: List<&2, U32>, +se: S.Session) ->
  {S.receive(S.receive.go(F.take(r), se), b) == S.receive.go(F.take(F.feed(r, b)), se) : S.Conn}:
  match r:
    case F.Rx{+rest, +dr}:
      +q0 = {F.Rx{rest, Nil{}} : F.Rx}
      %Equal.sym(F.Rx, F.feed(app(q0, dr), b), app(F.feed(q0, b), dr), feed_app(b, dr, q0))
        : {S.receive(S.receive.go(F.take(F.Rx{rest, dr}), se), b)
          == S.receive.go(F.take(_), se) : S.Conn}
      took(F.feed(q0, b), dr, se)

def Laws.receive_split(c, a, b):
  match c:
    case S.Conn{+rx, +se}:
      %Laws.feed_split(a, b, rx) : {S.receive(S.receive.go(F.take(F.feed(rx, a)), se), b) == S.receive.go(F.take(_), se) : S.Conn}
      split(F.feed(rx, a), b, se)
