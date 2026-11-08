# Blink's laws: facts about the pure pipeline that must always hold.
# PROOF.bend proves each one; `bend PROOF.bend` is the gate.
import Base
import ./blink/bytes.bend as B
import ./blink/frame.bend as F
import ./blink/wire.bend as W
import ./blink/rows.bend as R
import ./blink/auth.bend as A
import ./blink/session.bend as S

# Three messages: ReadyForQuery, a DataRow (a NULL and "hé"),
# CommandComplete. Bytes from Python's struct.
def stream() -> List<&2, U32>:
  [90, 0, 0, 0, 5, 73, 68, 0, 0, 0, 17, 0, 2, 255, 255, 255, 255, 0, 0, 0, 3, 104, 195, 169,
    67, 0, 0, 0, 13, 83, 69, 76, 69, 67, 84, 32, 49, 0]

# The stream cut into two reads at k, for every k from n down to 0.
def splits(+n: Nat) -> List<&2, F.Rx>:
  match n:
    case 0n:
      [F.feed(F.feed(F.new(), Nil{}), stream())]
    case 1n+p:
      F.feed(F.feed(F.new(), List.take(&2, U32, stream(), n)), List.drop(&2, U32, stream(), n))
        <> splits(p)

# LAW: how TCP cuts the stream into reads never changes what the framer
# sees: at every one of the 39 places to cut it, two reads frame exactly as
# one does, down to the DataRow's cells.
law feed_split:
  {splits(38n) == List.replicate(F.Rx, 39n, F.feed(F.new(), stream())) : List<&2, F.Rx>}

law feed_frames:
  {Pair.fst(List<&2, F.Frame>, F.Rx, F.take(F.feed(F.new(), stream())))
    == [F.Frame{90, [73]}, F.Frame.Row{[None{}, Some{[104, 195, 169]}]},
      F.Frame{67, [83, 69, 76, 69, 67, 84, 32, 49, 0]}] : List<&2, F.Frame>}

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
    S.connect("u", "pw", "db", Nil{}, [S.Query.Simple{"SELECT 1"}]),
    List.concat(&2, U32, [[82, 0, 0, 0, 8, 0, 0, 0, 12], [82, 0, 0, 0, 8, 0, 0, 0, 0],
      [90, 0, 0, 0, 5, 73]]))))
    == W.startup("u", "db") : List<&2, U32>}

# LAW: an extended query is Parse, Bind (UTF-8 lengths in bytes, NULL as
# -1), Describe, Execute for one batch, and Flush, which keeps the portal
# open. Bytes from Python's struct.
law extended_bytes:
  {Pair.snd(S.Run, List<&2, U32>, S.start(S.Query.Extended{"SELECT $1, $2", [Some{"é"}, None{}], 2, 100}))
    == [80, 0, 0, 0, 21, 0, 83, 69, 76, 69, 67, 84, 32, 36, 49, 44, 32, 36, 50, 0, 0, 0,
      66, 0, 0, 0, 22, 0, 0, 0, 0, 0, 2, 0, 0, 0, 2, 195, 169, 255, 255, 255, 255, 0, 0,
      68, 0, 0, 0, 6, 80, 0, 69, 0, 0, 0, 9, 0, 0, 0, 0, 2, 72, 0, 0, 0, 4] : List<&2, U32>}

# A session logged in (trust) with key 7/9, running a query 2 rows at a time.
def batching() -> S.Conn:
  Pair.snd(List<&2, U32>, S.Conn, S.take(S.receive(
    S.connect("u", "", "db", Nil{}, [S.Query.Extended{"SELECT 1", [], 2, 100}]),
    List.concat(&2, U32, [[82, 0, 0, 0, 8, 0, 0, 0, 0], [75, 0, 0, 0, 12, 0, 0, 0, 7, 0, 0, 0, 9],
      [90, 0, 0, 0, 5, 73]]))))

# LAW: a batch done (PortalSuspended), the session asks for the next.
law batches_continue:
  {Pair.fst(List<&2, U32>, S.Conn, S.take(S.receive(batching(), [115, 0, 0, 0, 4])))
    == List.append(&2, U32, W.execute(2), W.flush()) : List<&2, U32>}

# LAW: once cancelled, it asks for no more, but closes the portal and syncs;
# the cancel itself is a CancelRequest with the server's key.
law cancel_stops_batches:
  {(Pair.fst(List<&2, U32>, S.Conn, S.cancel(batching())),
    Pair.fst(List<&2, U32>, S.Conn, S.take(S.receive(Pair.snd(List<&2, U32>, S.Conn, S.cancel(batching())),
      [115, 0, 0, 0, 4]))))
    == ([0, 0, 0, 16, 4, 210, 22, 46, 0, 0, 0, 7, 0, 0, 0, 9], [67, 0, 0, 0, 6, 80, 0, 83, 0, 0, 0, 4])
    : List<&2, U32> & List<&2, U32>}

# LAW: a second missed deadline, after the cancel went unanswered (or there
# was no key to send), closes the connection instead of waiting forever.
law cancel_bounded:
  {(Pair.fst(List<&2, U32>, S.Conn, S.cancel(Pair.snd(List<&2, U32>, S.Conn, S.cancel(batching())))),
    S.open(Pair.snd(List<&2, U32>, S.Conn, S.cancel(Pair.snd(List<&2, U32>, S.Conn, S.cancel(batching()))))))
    == (Nil{}, False{}) : List<&2, U32> & Bool}

# A session logged in (trust) running q, given CopyInResponse and then the
# error that follows CopyFail: what it sends.
def copying(q: S.Query) -> List<&2, U32>:
  Pair.fst(List<&2, U32>, S.Conn, S.take(S.receive(
    Pair.snd(List<&2, U32>, S.Conn, S.take(S.receive(S.connect("u", "", "db", Nil{}, [q]),
      List.append(&2, U32, [82, 0, 0, 0, 8, 0, 0, 0, 0], [90, 0, 0, 0, 5, 73])))),
    List.append(&2, U32, [71, 0, 0, 0, 9, 0, 0, 1, 0, 0],
      [69, 0, 0, 0, 22, 83, 69, 82, 82, 79, 82, 0, 67, 53, 55, 48, 49, 52, 0, 77, 120, 0, 0]))))

# LAW: COPY FROM STDIN is refused with CopyFail rather than left waiting. An
# extended query also needs a Sync, since the server ignored the one sent
# during copy-in; a simple one must not get one. Bytes from Python's struct.
law copy_in_refused:
  {(copying(S.Query.Simple{"COPY t FROM STDIN"}), copying(S.Query.Extended{"COPY t FROM STDIN", [], 0, 0}))
    == ([102, 0, 0, 0, 31, 66, 108, 105, 110, 107, 32, 99, 97, 110, 39, 116, 32, 115, 101, 110, 100, 32,
        67, 79, 80, 89, 32, 100, 97, 116, 97, 0],
      [102, 0, 0, 0, 31, 66, 108, 105, 110, 107, 32, 99, 97, 110, 39, 116, 32, 115, 101, 110, 100, 32,
        67, 79, 80, 89, 32, 100, 97, 116, 97, 0, 83, 0, 0, 0, 4]) : List<&2, U32> & List<&2, U32>}

# LAW: a wrong SCRAM signature reaches the caller as Blink's Refused, not as
# an Error the server could have sent.
law forged_scram_refused:
  {S.replies(S.receive(S.Conn{F.new(), S.Session{0, A.Login.Verify{B.utf8("BBBB")}, Nil{},
      S.Run{True{}, 0, 0, True{}, False{}}, Nil{}, Nil{}, Nil{}, S.Log{Nil{}, 0, Nil{}}}},
      [82, 0, 0, 0, 14, 0, 0, 0, 12, 118, 61, 65, 65, 65, 65]))
    == [S.Reply.Refused{"the server's SCRAM signature is wrong"}] : List<&2, S.Reply>}

# Chunks of replies with rows among them, oldest chunk first and each
# newest-first, as the session logs them; for decode_keeps_order.
def mixed() -> List<&2, List<&2, S.Item>>:
  [[S.Item.Row{[W.Field{"n", 23}], [Some{[49]}]}, S.Item.Reply{S.Reply.Columns{[W.Field{"n", 23}]}}],
    [S.Item.Row{[W.Field{"n", 23}], [None{}]}, S.Item.Row{[W.Field{"n", 23}], [Some{[50]}]}],
    [S.Item.Reply{S.Reply.Complete{"SELECT 3"}}],
    [S.Item.Reply{S.Reply.Complete{"SELECT 1"}}, S.Item.Row{[W.Field{"t", 25}], [Some{[104, 105]}]}]]

# LAW: decoding chunks in parallel lanes (8 here, some empty) gives exactly
# the replies, in exactly the order, that decoding them one by one does.
law decode_keeps_order:
  {List.concat(&2, S.Reply, S.decode(3n, S.deal(mixed())))
    == List.concat(&2, S.Reply, S.chunks(mixed())) : List<&2, S.Reply>}
