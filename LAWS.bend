# Blink's laws: facts about the pure pipeline that must always hold.
# PROOF.bend proves each one; `bend PROOF.bend` is the gate, and
# `bend PROOF.bend --verdict` rechecks the proofs with BendTT's kernel,
# which has a proof in Lean.
#
# The first laws hold for every input: every byte stream and every way TCP
# cuts it, every session state, every server message. The vectors after
# them pin exact bytes (from Python's struct) on samples.
import Base
import ./blink/bytes.bend as B
import ./blink/frame.bend as F
import ./blink/wire.bend as W
import ./blink/rows.bend as R
import ./blink/auth.bend as A
import ./blink/session.bend as S

# ---- for every input

# LAW: how TCP cuts the stream into reads never changes what the framer
# sees: feeding a then b is feeding a ++ b, for every a, b and state.
law feed_split:
  for +a: List<&2, U32>
  for +b: List<&2, U32>
  for rx: F.Rx
  {F.feed(F.feed(rx, a), b) == F.feed(rx, List.append(&2, U32, a, b)) : F.Rx}

# LAW: nor what the connection does: receiving a then b is receiving
# a ++ b, for every connection, so the same frames, replies and bytes to
# send.
law receive_split:
  for c: S.Conn
  for +a: List<&2, U32>
  for +b: List<&2, U32>
  {S.receive(S.receive(c, a), b) == S.receive(c, List.append(&2, U32, a, b)) : S.Conn}

# LAW: decoding chunks of replies in 2^depth parallel lanes gives exactly
# the chunks, in exactly the order, that decoding them one by one does, for
# every depth and every chunks.
law decode_keeps_order:
  for depth: Nat
  for +cs: List<&2, List<&2, S.Item>>
  {S.decode(depth, S.deal(cs)) == S.chunks(cs) : List<&2, List<&2, S.Reply>>}

# LAW: a login Blink refuses (auth.bend's Fail, such as a wrong SCRAM
# signature) fails the session, and the caller gets Refused.
law refused_login_fails:
  for +code: U32
  for +data: List<&2, U32>
  for +login: A.Login
  for +m: String
  for e: {A.answer(code, data, login) == A.Answer.Fail{m} : A.Answer}
  for +queue: List<&2, S.Query>
  for +run: S.Run
  for +key: List<&2, U32>
  for +fields: List<&2, W.Field>
  for +out: List<&2, U32>
  for +log: S.Log
  {S.react(S.Session{0, login, queue, run, key, fields, out, log}, W.Backend.Auth{code, data})
    == S.Session{3, A.Login.Done{}, queue, run, key, fields, out, S.push(log, S.Item.Reply{S.Reply.Refused{m}})}
    : S.Session}

# LAW: a failed session takes nothing more: every message leaves every
# failed state as it was, so whatever the server sends after a failed
# login, such as its own AuthenticationOk and ReadyForQuery, sends no
# query.
law failed_inert:
  for login: A.Login
  for queue: List<&2, S.Query>
  for run: S.Run
  for key: List<&2, U32>
  for fields: List<&2, W.Field>
  for out: List<&2, U32>
  for log: S.Log
  for msg: W.Backend
  {S.react(S.Session{3, login, queue, run, key, fields, out, log}, msg)
    == S.Session{3, login, queue, run, key, fields, out, log} : S.Session}

# LAW: SCRAM finishes only if the server's signature is exactly the one
# Blink expects, so a server that doesn't know the password can't log in.
law scram_signature_checked:
  for +data: List<&2, U32>
  for +sig: List<&2, U32>
  for e: {A.answer(12, data, A.Login.Verify{sig}) == A.Answer.Send{A.Login.Done{}, Nil{}} : A.Answer}
  {A.scram.signature(A.attrs(data)) == sig : List<&2, U32>}

# LAW: and it does finish when the signature is the one expected.
law scram_signature_accepted:
  for +data: List<&2, U32>
  {A.answer(12, data, A.Login.Verify{A.scram.signature(A.attrs(data))})
    == A.Answer.Send{A.Login.Done{}, Nil{}} : A.Answer}

# LAW: nor can a server skip the proof and declare the login done, at
# either SCRAM step.
law scram_not_skipped:
  for data: List<&2, U32>
  for sig: List<&2, U32>
  for password: String
  for nonce: List<&2, U32>
  {(A.answer(0, data, A.Login.Verify{sig}), A.answer(0, data, A.Login.Scram{password, nonce}))
    == (A.Answer.Fail{"the server ended SCRAM without proving it knows the password"},
      A.Answer.Fail{"the server ended SCRAM without proving it knows the password"}) : A.Answer & A.Answer}

# LAW: an error during a query whose Sync isn't sent sends exactly one,
# since the server skips everything up to it...
law error_syncs:
  for login: A.Login
  for queue: List<&2, S.Query>
  for simple: Bool
  for fetch: U32
  for timeout: U32
  for stopped: Bool
  for key: List<&2, U32>
  for fields: List<&2, W.Field>
  for out: List<&2, U32>
  for log: S.Log
  for sev: String
  for code: String
  for m: String
  {S.react(S.Session{1, login, queue, S.Run{simple, fetch, timeout, False{}, stopped}, key, fields, out, log},
      W.Backend.Error{sev, code, m})
    == S.Session{1, login, queue, S.Run{simple, fetch, timeout, True{}, stopped}, key, fields,
      List.append(&2, U32, out, W.sync()), S.push(log, S.Item.Reply{S.Reply.Error{sev, code, m}})} : S.Session}

# LAW: ...and one whose Sync is sent sends nothing.
law error_after_sync:
  for login: A.Login
  for queue: List<&2, S.Query>
  for simple: Bool
  for fetch: U32
  for timeout: U32
  for stopped: Bool
  for key: List<&2, U32>
  for fields: List<&2, W.Field>
  for out: List<&2, U32>
  for log: S.Log
  for sev: String
  for code: String
  for m: String
  {S.react(S.Session{1, login, queue, S.Run{simple, fetch, timeout, True{}, stopped}, key, fields, out, log},
      W.Backend.Error{sev, code, m})
    == S.Session{1, login, queue, S.Run{simple, fetch, timeout, True{}, stopped}, key, fields,
      out, S.push(log, S.Item.Reply{S.Reply.Error{sev, code, m}})} : S.Session}

# LAW: a batch done (PortalSuspended), a query not cancelled asks for the
# next...
law batches_continue:
  for login: A.Login
  for queue: List<&2, S.Query>
  for simple: Bool
  for fetch: U32
  for timeout: U32
  for synced: Bool
  for key: List<&2, U32>
  for fields: List<&2, W.Field>
  for out: List<&2, U32>
  for log: S.Log
  {S.react(S.Session{1, login, queue, S.Run{simple, fetch, timeout, synced, False{}}, key, fields, out, log},
      W.Backend.Suspended{})
    == S.Session{1, login, queue, S.Run{simple, fetch, timeout, synced, False{}}, key, fields,
      List.concat(&2, U32, [out, W.execute(fetch), W.flush()]), log} : S.Session}

# LAW: ...and a cancelled one asks for no more, but closes the portal and
# syncs.
law cancelled_batches_close:
  for login: A.Login
  for queue: List<&2, S.Query>
  for simple: Bool
  for fetch: U32
  for timeout: U32
  for synced: Bool
  for key: List<&2, U32>
  for fields: List<&2, W.Field>
  for out: List<&2, U32>
  for log: S.Log
  {S.react(S.Session{1, login, queue, S.Run{simple, fetch, timeout, synced, True{}}, key, fields, out, log},
      W.Backend.Suspended{})
    == S.Session{1, login, queue, S.Run{simple, fetch, timeout, True{}, True{}}, key, fields,
      List.concat(&2, U32, [out, W.close(), W.sync()]), log} : S.Session}

# LAW: the first missed deadline stops the query: the shell gets the
# server's CancelRequest to send, the caller gets Cancelled...
law cancel_once:
  for rx: F.Rx
  for phase: U32
  for login: A.Login
  for queue: List<&2, S.Query>
  for simple: Bool
  for fetch: U32
  for timeout: U32
  for synced: Bool
  for +key: List<&2, U32>
  for fields: List<&2, W.Field>
  for out: List<&2, U32>
  for log: S.Log
  {S.cancel(S.Conn{rx, S.Session{phase, login, queue, S.Run{simple, fetch, timeout, synced, False{}}, key, fields,
      out, log}})
    == (key, S.Conn{rx, S.Session{phase, login, queue, S.Run{simple, fetch, timeout, synced, True{}}, key, fields,
      out, S.push(log, S.Item.Reply{S.Reply.Cancelled{}})}}) : List<&2, U32> & S.Conn}

# LAW: ...and a second, after the cancel went unanswered (or there was no
# key to send), sends nothing and closes the connection instead of waiting
# forever.
law cancel_bounded:
  for rx: F.Rx
  for phase: U32
  for login: A.Login
  for queue: List<&2, S.Query>
  for simple: Bool
  for fetch: U32
  for timeout: U32
  for synced: Bool
  for key: List<&2, U32>
  for fields: List<&2, W.Field>
  for out: List<&2, U32>
  for log: S.Log
  {(Pair.fst(List<&2, U32>, S.Conn, S.cancel(S.Conn{rx, S.Session{phase, login, queue,
      S.Run{simple, fetch, timeout, synced, True{}}, key, fields, out, log}})),
    S.open(Pair.snd(List<&2, U32>, S.Conn, S.cancel(S.Conn{rx, S.Session{phase, login, queue,
      S.Run{simple, fetch, timeout, synced, True{}}, key, fields, out, log}}))))
    == (Nil{}, False{}) : List<&2, U32> & Bool}

# LAW: COPY FROM STDIN is refused with CopyFail rather than left waiting.
# The server ignores a Sync sent during copy-in, so the query counts as
# synced only if it is simple: by error_syncs and error_after_sync, the
# error that answers CopyFail then sends a Sync for an extended query and
# none for a simple one.
law copy_in_refused:
  for login: A.Login
  for queue: List<&2, S.Query>
  for simple: Bool
  for fetch: U32
  for timeout: U32
  for synced: Bool
  for stopped: Bool
  for key: List<&2, U32>
  for fields: List<&2, W.Field>
  for out: List<&2, U32>
  for log: S.Log
  {S.react(S.Session{1, login, queue, S.Run{simple, fetch, timeout, synced, stopped}, key, fields, out, log},
      W.Backend.CopyIn{})
    == S.Session{1, login, queue, S.Run{simple, fetch, timeout, simple, stopped}, key, fields,
      List.append(&2, U32, out, W.copy_fail("Blink can't send COPY data")), log} : S.Session}

# ---- Base's Bytes (bendlang/bend#1573), which the framer cuts cells
# from. In the theory Bytes is its list, as a U32 is its Word, so a slice
# is the list's take of its drop; compiled, it shares the read's block.

# LAW: a slice's bytes are the bytes from o, at most n of them.
law bytes_slice:
  for b: Bytes
  for o: Nat
  for n: Nat
  {Bytes.to_list(Bytes.slice(b, o, n))
    == List.take(&2, U32, List.drop(&2, U32, Bytes.to_list(b), o), n) : List<&2, U32>}

# LAW: and how many there are.
law bytes_slice_length:
  for b: Bytes
  for +o: Nat
  for +n: Nat
  {Bytes.length(Bytes.slice(b, o, n)) == Nat.min(n, Nat.sub(Bytes.length(b), o)) : Nat}

# LAW: concat is append.
law bytes_concat:
  for a: Bytes
  for b: Bytes
  {Bytes.to_list(Bytes.concat(a, b)) == List.append(&2, U32, Bytes.to_list(a), Bytes.to_list(b))
    : List<&2, U32>}

# LAW: a copy is the same value: only where its bytes live changes.
law bytes_copy:
  for b: Bytes
  {Bytes.copy(b) == b : Bytes}

# ---- vectors

# Three messages: ReadyForQuery, a DataRow (a NULL and "hé"),
# CommandComplete. Bytes from Python's struct.
def stream() -> List<&2, U32>:
  [90, 0, 0, 0, 5, 73, 68, 0, 0, 0, 17, 0, 2, 255, 255, 255, 255, 0, 0, 0, 3, 104, 195, 169,
    67, 0, 0, 0, 13, 83, 69, 76, 69, 67, 84, 32, 49, 0]

# LAW: the framer cuts each message whole, and a DataRow into its cells:
# here a NULL and "hé".
law feed_frames:
  {Pair.fst(List<&2, F.Frame>, F.Rx, F.take(F.feed(F.new(), stream())))
    == [F.Frame{90, [73]}, F.Frame.Row{[None{}, Some{Bytes{[104, 195, 169]}}]},
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
  {R.decode([R.Col.Int{}, R.Col.Text{}], [Some{Bytes{[45, 52, 50]}}, None{}])
    == (Some{R.Int{True{}, 42}}, (None{}, Unit{})) : R.Row([R.Col.Int{}, R.Col.Text{}])}

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

# LAW: on the wire, a cancel is a CancelRequest with the server's key, and
# the next batch done closes the portal and syncs.
law cancel_bytes:
  {(Pair.fst(List<&2, U32>, S.Conn, S.cancel(batching())),
    Pair.fst(List<&2, U32>, S.Conn, S.take(S.receive(Pair.snd(List<&2, U32>, S.Conn, S.cancel(batching())),
      [115, 0, 0, 0, 4]))))
    == ([0, 0, 0, 16, 4, 210, 22, 46, 0, 0, 0, 7, 0, 0, 0, 9], [67, 0, 0, 0, 6, 80, 0, 83, 0, 0, 0, 4])
    : List<&2, U32> & List<&2, U32>}

# A session logged in (trust) running q, given CopyInResponse and then the
# error that follows CopyFail: what it sends.
def copying(q: S.Query) -> List<&2, U32>:
  Pair.fst(List<&2, U32>, S.Conn, S.take(S.receive(
    Pair.snd(List<&2, U32>, S.Conn, S.take(S.receive(S.connect("u", "", "db", Nil{}, [q]),
      List.append(&2, U32, [82, 0, 0, 0, 8, 0, 0, 0, 0], [90, 0, 0, 0, 5, 73])))),
    List.append(&2, U32, [71, 0, 0, 0, 9, 0, 0, 1, 0, 0],
      [69, 0, 0, 0, 22, 83, 69, 82, 82, 79, 82, 0, 67, 53, 55, 48, 49, 52, 0, 77, 120, 0, 0]))))

# LAW: on the wire, end to end: CopyFail, then a Sync for the extended
# query only. Bytes from Python's struct.
law copy_in_bytes:
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
