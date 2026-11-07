# Authentication: what the client answers to each request the server makes
# during startup. Trust, cleartext, MD5 and SCRAM-SHA-256 (RFC 5802, 7677),
# without channel binding, as libpq does over plain TCP. Pure: the random
# SCRAM nonce comes in with the login.
import Base
import ./bytes.bend as B
import ./crypto.bend as C
import ./wire.bend as W

# Where a login stands. Start holds what the server may ask for; Scram waits
# for the server's first SCRAM message, Verify for its signature.
type Login is Data:
  Login.Start{user: String, password: String, nonce: List<&2, U32>}
  Login.Scram{password: String, nonce: List<&2, U32>}
  Login.Verify{signature: List<&2, U32>}
  Login.Done{}

type Answer is Data:
  Answer.Send{login: Login, bytes: List<&2, U32>}
  Answer.Fail{message: String}

# ---- MD5: "md5" ++ hex(md5(hex(md5(password ++ user)) ++ salt))

def md5_password(password: String, user: String, salt: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, B.utf8("md5"), C.hex(C.md5(List.append(&2, U32,
    C.hex(C.md5(List.append(&2, U32, B.utf8(password), B.utf8(user)))), salt))))

# ---- SCRAM-SHA-256

# client-first-message-bare. The user goes empty, as libpq sends it: the
# server takes the startup message's.
def scram.bare(nonce: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, B.utf8("n=,r="), nonce)

# The server's "k=value,..." attributes that SCRAM reads, by a fold over
# the bytes: pos 0 reads a key, 1 its "=", 2 its value up to a comma.
type Attrs is Data:
  Attrs{pos: U32, key: U32, cur: List<&2, U32>, r: List<&2, U32>, s: List<&2, U32>,
    i: List<&2, U32>, v: List<&2, U32>}

def attrs.keep(+key: U32, val: List<&2, U32>, r: List<&2, U32>, s: List<&2, U32>,
  i: List<&2, U32>, v: List<&2, U32>) -> Attrs:
  match key:
    case 114:
      Attrs{0, 0, Nil{}, val, s, i, v}
    case 115:
      Attrs{0, 0, Nil{}, r, val, i, v}
    case 105:
      Attrs{0, 0, Nil{}, r, s, val, v}
    case 118:
      Attrs{0, 0, Nil{}, r, s, i, val}
    case _:
      Attrs{0, 0, Nil{}, r, s, i, v}

def attrs.at(+pos: U32, comma: Bool, b: U32, +key: U32, cur: List<&2, U32>, r: List<&2, U32>,
  s: List<&2, U32>, i: List<&2, U32>, v: List<&2, U32>) -> Attrs:
  match pos comma:
    case 0 _:
      Attrs{1, b, Nil{}, r, s, i, v}
    case 1 _:
      Attrs{2, key, Nil{}, r, s, i, v}
    case _ True{}:
      attrs.keep(key, List.reverse(&2, U32, cur), r, s, i, v)
    case _ False{}:
      Attrs{pos, key, b <> cur, r, s, i, v}

def attrs.step(a: Attrs, +b: U32) -> Attrs:
  match a:
    case Attrs{pos, key, cur, r, s, i, v}:
      attrs.at(pos, U32.is_eq(b, 44), b, key, cur, r, s, i, v)

def attrs.end(a: Attrs) -> Attrs:
  match a:
    case Attrs{pos, key, cur, r, s, i, v}:
      attrs.keep(key, List.reverse(&2, U32, cur), r, s, i, v)

def attrs(bytes: List<&2, U32>) -> Attrs:
  attrs.end(List.foldl(~&2, ~U32, ~Attrs, ~(a => b => attrs.step(a, b)), bytes,
    Attrs{0, 0, Nil{}, Nil{}, Nil{}, Nil{}, Nil{}}))

# What the client sends last, what the server must sign back with, and
# whether the server's nonce extends ours.
type Proof is Data:
  Proof{final: List<&2, U32>, signature: List<&2, U32>, ok: Bool}

def scram.prove(password: String, bare: List<&2, U32>, nonce: List<&2, U32>,
  +server_first: List<&2, U32>, a: Attrs) -> Proof:
  match a:
    case Attrs{pos, key, cur, +r, s, i, v}:
      +without = List.append(&2, U32, B.utf8("c=biws,r="), r)
      +message = List.concat(&2, U32, [bare, [44], server_first, [44], without])
      +salted = C.pbkdf2(B.utf8(password), C.unbase64(s),
        U32.to_nat(Maybe.default(&2, U32, U32.read(B.text(i)), 0)))
      +client_key = C.hmac(salted, B.utf8("Client Key"))
      Proof{List.concat(&2, U32, [without, B.utf8(",p="),
          C.base64(C.xor(client_key, C.hmac(C.sha256(client_key), message)))]),
        C.base64(C.hmac(C.hmac(salted, B.utf8("Server Key")), message)),
        B.starts_with(r, nonce)}

# From the password, our first message's bare part and nonce, and the
# server's first message.
def scram.proof(password: String, bare: List<&2, U32>, nonce: List<&2, U32>,
  +server_first: List<&2, U32>) -> Proof:
  scram.prove(password, bare, nonce, server_first, attrs(server_first))

def scram.signature(a: Attrs) -> List<&2, U32>:
  match a:
    case Attrs{pos, key, cur, r, s, i, v}:
      v

def is_scram(m: List<&2, U32>) -> Bool:
  B.eq(m, B.utf8("SCRAM-SHA-256"))

# ---- answers, by request code

def fail(what: String) -> Answer:
  Answer.Fail{what}

def ok(login: Login) -> Answer:
  match login:
    case Login.Scram{password, nonce}:
      fail("the server ended SCRAM without proving it knows the password")
    case Login.Verify{signature}:
      fail("the server ended SCRAM without proving it knows the password")
    case _:
      Answer.Send{Login.Done{}, Nil{}}

def cleartext(login: Login) -> Answer:
  match login:
    case Login.Start{user, password, nonce}:
      Answer.Send{Login.Done{}, W.password(B.utf8(password))}
    case _:
      fail("unexpected password request")

def md5(login: Login, data: List<&2, U32>) -> Answer:
  match login:
    case Login.Start{user, password, nonce}:
      Answer.Send{Login.Done{}, W.password(md5_password(password, user, List.take(&2, U32, data, 4n)))}
    case _:
      fail("unexpected MD5 request")

def sasl(login: Login, scram: Bool) -> Answer:
  match login scram:
    case Login.Start{user, password, +nonce} True{}:
      Answer.Send{Login.Scram{password, nonce},
        W.sasl_initial("SCRAM-SHA-256", List.append(&2, U32, B.utf8("n,,"), scram.bare(nonce)))}
    case _ False{}:
      fail("the server offers no SCRAM-SHA-256")
    case _ _:
      fail("unexpected SASL request")

def proved(p: Proof) -> Answer:
  match p:
    case Proof{final, signature, ok}:
      match ok:
        case True{}:
          Answer.Send{Login.Verify{signature}, W.sasl_response(final)}
        case False{}:
          fail("the server's SCRAM nonce does not extend ours")

def sasl_continue(login: Login, data: List<&2, U32>) -> Answer:
  match login:
    case Login.Scram{password, +nonce}:
      proved(scram.proof(password, scram.bare(nonce), nonce, data))
    case _:
      fail("unexpected SASL continue")

def verified(same: Bool) -> Answer:
  match same:
    case True{}:
      Answer.Send{Login.Done{}, Nil{}}
    case False{}:
      fail("the server's SCRAM signature is wrong")

def sasl_final(login: Login, data: List<&2, U32>) -> Answer:
  match login:
    case Login.Verify{signature}:
      verified(B.eq(scram.signature(attrs(data)), signature))
    case _:
      fail("unexpected SASL final")

# The answer to request code with its data.
def answer(+code: U32, data: List<&2, U32>, login: Login) -> Answer:
  match code:
    case 0:
      ok(login)
    case 3:
      cleartext(login)
    case 5:
      md5(login, data)
    case 10:
      sasl(login, List.any(~&2, ~List<&2, U32>, ~(m => is_scram(m)), B.cstrings(data)))
    case 11:
      sasl_continue(login, data)
    case 12:
      sasl_final(login, data)
    case _:
      fail("authentication request " ++ U32.show(code) ++ " is not supported")
