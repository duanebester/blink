# Blink's laws: facts about the pure pipeline that must always hold.
# PROOF.bend proves each one; `bend PROOF.bend` is the gate.
import Base
import ./blink/bytes.bend as B
import ./blink/frame.bend as F
import ./blink/wire.bend as W
import ./blink/rows.bend as R
import ./blink/auth.bend as A
import ./blink/session.bend as S

# LAW: how TCP cuts the stream into reads never changes what the framer
# sees: feeding a then b is feeding a ++ b.
law feed_split:
  for a: List<&2, U32>
  for b: List<&2, U32>
  for rx: F.Rx
  {F.feed(F.feed(rx, a), b) == F.feed(rx, List.append(&2, U32, a, b)) : F.Rx}

# LAW: text survives a trip through UTF-8, across every encoded width.
law utf8_sample:
  {B.text(B.utf8("aé€🐘")) == "aé€🐘" : String}

# LAW: a Query message is 'Q', its length, the SQL and a NUL.
law query_bytes:
  {W.query("SELECT 1") == [81, 0, 0, 0, 13, 83, 69, 76, 69, 67, 84, 32, 49, 0] : List<&2, U32>}

# LAW: a ReadyForQuery split across two reads frames whole.
law ready_split:
  {F.take(F.feed(F.feed(F.new(), [90, 0, 0]), [0, 5, 73]))
    == ([F.Frame{90, [73]}], F.new()) : List<&2, F.Frame> & F.Rx}

# LAW: an ErrorResponse decodes to its severity, SQLSTATE and message.
law error_fields:
  {W.decode(F.Frame{69, [83, 69, 0, 67, 52, 50, 0, 77, 104, 105, 0, 0]})
    == W.Backend.Error{"E", "42", "hi"} : W.Backend}

# LAW: a schema decides a row's type: int4 "-42" and a NULL text decode to
# exactly the tuple Row(schema) names.
law typed_row:
  {R.decode([R.Col.Int{}, R.Col.Text{}], [Some{[45, 52, 50]}, None{}])
    == (Some{R.Int{True{}, 42}}, (None{}, Unit{})) : R.Row([R.Col.Int{}, R.Col.Text{}])}

# LAW: SCRAM's last step accepts only the signature it expects, so a server
# that doesn't know the password can't finish the login.
law scram_signature_checked:
  {A.answer(12, B.utf8("v=AAAA"), A.Login.Verify{B.utf8("BBBB")})
    == A.Answer.Fail{"the server's SCRAM signature is wrong"} : A.Answer}

law scram_signature_accepted:
  {A.answer(12, B.utf8("v=BBBB"), A.Login.Verify{B.utf8("BBBB")})
    == A.Answer.Send{A.Login.Done{}, Nil{}} : A.Answer}

# LAW: nor can it skip the proof and declare the login done.
law scram_not_skipped:
  {A.answer(0, Nil{}, A.Login.Verify{B.utf8("BBBB")})
    == A.Answer.Fail{"the server ended SCRAM without proving it knows the password"} : A.Answer}

# LAW: once a login fails, nothing the server sends next starts a query:
# a SASL final out of turn, then AuthenticationOk and ReadyForQuery, leave
# nothing to send but the startup message.
law failed_login_stays_failed:
  {Pair.fst(List<&2, U32>, S.Conn, S.take(S.receive(
    S.connect("u", "pw", "db", Nil{}, ["SELECT 1"]),
    List.concat(&2, U32, [[82, 0, 0, 0, 8, 0, 0, 0, 12], [82, 0, 0, 0, 8, 0, 0, 0, 0],
      [90, 0, 0, 0, 5, 73]]))))
    == W.startup("u", "db") : List<&2, U32>}
