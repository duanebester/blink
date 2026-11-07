# The hashes, MACs and encodings authentication needs, in pure Bend: MD5,
# SHA-256, HMAC-SHA-256, PBKDF2-HMAC-SHA-256, base64 and hex. Bytes are
# List<&2, U32> as in bytes.bend; a hash state is a record of U32 words.
import Base
import ./bytes.bend as B

# ---- shared

def rotr(+x: U32, r: Nat, l: Nat) -> U32:
  ((x >> r) .|. (x << l) : U32)

# The nth word, 0 past the end.
def nth(xs: List<&2, U32>, n: Nat) -> U32:
  match xs n:
    case Nil{} _:
      0
    case h <> t 0n:
      h
    case h <> t 1n+p:
      nth(t, p)

def le32(+n: U32) -> List<&2, U32>:
  [(n .&. 255 : U32), ((n >> 8n) .&. 255 : U32), ((n >> 16n) .&. 255 : U32), (n >> 24n : U32)]

def words.be(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case a <> b <> c <> d <> rest:
      B.u32(a, b, c, d) <> words.be(rest)
    case _:
      Nil{}

def words.le(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case a <> b <> c <> d <> rest:
      B.u32(d, c, b, a) <> words.le(rest)
    case _:
      Nil{}

def bytes.be(ws: List<&2, U32>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> rest:
      List.append(&2, U32, B.be32(w), bytes.be(rest))

def bytes.le(ws: List<&2, U32>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> rest:
      List.append(&2, U32, le32(w), bytes.le(rest))

def xor(a: List<&2, U32>, b: List<&2, U32>) -> List<&2, U32>:
  match a b:
    case x <> xs y <> ys:
      (x .^. y : U32) <> xor(xs, ys)
    case _ _:
      Nil{}

def xor.each(+x: U32, xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      (h .^. x : U32) <> xor.each(x, t)

# Merkle-Damgard padding for a message of total bytes: 0x80, zeros, then
# its length in bits (len, 8 bytes in the hash's byte order), ending on 64.
def pad(+total: U32, len: List<&2, U32>) -> List<&2, U32>:
  128 <> List.append(&2, U32,
    List.replicate(U32, U32.to_nat(((64 - ((total + 9) % 64)) % 64 : U32)), 0), len)

# How many 64-byte blocks a padded message holds.
def blocks.count(+padded: List<&2, U32>) -> Nat:
  Nat.div(List.length(&2, U32, padded), 64n)

# ---- SHA-256 (FIPS 180-4)

type Sha is Data:
  Sha{a: U32, b: U32, c: U32, d: U32, e: U32, f: U32, g: U32, h: U32}

def sha.iv() -> Sha:
  Sha{1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635,
    1541459225}

def sha.k() -> List<&2, U32>:
  [
  1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221,
  3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580,
  3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
  2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895,
  666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037,
  2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
  430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779,
  1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298]

def sha.round(st: Sha, k: U32, w: U32) -> Sha:
  match st:
    case Sha{+a, +b, +c, d, +e, +f, +g, h}:
      +t1 = (h + (rotr(e, 6n, 26n) .^. (rotr(e, 11n, 21n) .^. rotr(e, 25n, 7n)))
        + ((e .&. f) .^. (U32.not(e) .&. g)) + k + w : U32)
      +t2 = ((rotr(a, 2n, 30n) .^. (rotr(a, 13n, 19n) .^. rotr(a, 22n, 10n)))
        + ((a .&. b) .^. ((a .&. c) .^. (b .&. c))) : U32)
      Sha{(t1 + t2 : U32), a, b, c, (d + t1 : U32), e, f, g}

# The message schedule as a window of 16 words: each round reads w0, then
# the window drops it and takes the next word. A record, not a list, since
# every round reads it.
type Sched is Data:
  Sched{w0: U32, w1: U32, w2: U32, w3: U32, w4: U32, w5: U32, w6: U32, w7: U32, w8: U32, w9: U32, w10: U32, w11: U32, w12: U32, w13: U32, w14: U32, w15: U32}

def sha.window(+ws: List<&2, U32>) -> Sched:
  Sched{nth(ws, 0n), nth(ws, 1n), nth(ws, 2n), nth(ws, 3n), nth(ws, 4n), nth(ws, 5n), nth(ws, 6n), nth(ws, 7n), nth(ws, 8n), nth(ws, 9n), nth(ws, 10n), nth(ws, 11n), nth(ws, 12n), nth(ws, 13n), nth(ws, 14n), nth(ws, 15n)}

def sha.rounds(ks: List<&2, U32>, st: Sha, w: Sched) -> Sha:
  match ks w:
    case Nil{} _:
      st
    case k <> rest Sched{+w0, +w1, w2, w3, w4, w5, w6, w7, w8, +w9, w10, w11, w12, w13, +w14, w15}:
      sha.rounds(rest, sha.round(st, k, w0), Sched{w1, w2, w3, w4, w5, w6, w7, w8, w9, w10, w11, w12, w13, w14, w15,
        (w0 + (rotr(w1, 7n, 25n) .^. (rotr(w1, 18n, 14n) .^. (w1 >> 3n))) + w9
          + (rotr(w14, 17n, 15n) .^. (rotr(w14, 19n, 13n) .^. (w14 >> 10n))) : U32)})

def sha.add(x: Sha, y: Sha) -> Sha:
  match x y:
    case Sha{a, b, c, d, e, f, g, h} Sha{a2, b2, c2, d2, e2, f2, g2, h2}:
      Sha{(a + a2 : U32), (b + b2 : U32), (c + c2 : U32), (d + d2 : U32), (e + e2 : U32),
        (f + f2 : U32), (g + g2 : U32), (h + h2 : U32)}

# One 16-word block in.
def sha.compress(+st: Sha, block: List<&2, U32>) -> Sha:
  sha.add(st, sha.rounds(sha.k(), st, sha.window(block)))

def sha.blocks(n: Nat, st: Sha, +ws: List<&2, U32>) -> Sha:
  match n:
    case 0n:
      st
    case 1n+p:
      sha.blocks(p, sha.compress(st, List.take(&2, U32, ws, 16n)), List.drop(&2, U32, ws, 16n))

def sha.words(st: Sha) -> List<&2, U32>:
  match st:
    case Sha{a, b, c, d, e, f, g, h}:
      [a, b, c, d, e, f, g, h]

# The state after bytes, which follow prefix bytes already in st.
def sha.from(st: Sha, +prefix: U32, +bytes: List<&2, U32>) -> Sha:
  +total = (prefix + U32.from_nat(List.length(&2, U32, bytes)) : U32)
  +padded = List.append(&2, U32, bytes, pad(total,
    List.append(&2, U32, B.be32((total >> 29n : U32)), B.be32((total << 3n : U32)))))
  sha.blocks(blocks.count(padded), st, words.be(padded))

def sha256(bytes: List<&2, U32>) -> List<&2, U32>:
  bytes.be(sha.words(sha.from(sha.iv(), 0, bytes)))

# ---- HMAC-SHA-256 (RFC 2104), with the key's two padded blocks compressed
# once, since PBKDF2 reuses the key thousands of times

type Mac is Data:
  Mac{inner: Sha, outer: Sha}

def mac.fit(long: Bool, +key: List<&2, U32>) -> List<&2, U32>:
  match long:
    case True{}:
      sha256(key)
    case False{}:
      key

def mac.zeros(+key: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, key, List.replicate(U32, Nat.sub(64n, List.length(&2, U32, key)), 0))

def mac.key(+key: List<&2, U32>) -> Mac:
  +k = mac.zeros(mac.fit(Nat.is_gt(List.length(&2, U32, key), 64n), key))
  Mac{sha.compress(sha.iv(), words.be(xor.each(54, k))),
    sha.compress(sha.iv(), words.be(xor.each(92, k)))}

def mac.with(m: Mac, msg: List<&2, U32>) -> Sha:
  match m:
    case Mac{inner, outer}:
      sha.from(outer, 64, bytes.be(sha.words(sha.from(inner, 64, msg))))

def hmac(+key: List<&2, U32>, msg: List<&2, U32>) -> List<&2, U32>:
  bytes.be(sha.words(mac.with(mac.key(key), msg)))

# The padding of a 32-byte message after a 64-byte key block: 768 bits.
def mac.pad32() -> List<&2, U32>:
  [2147483648, 0, 0, 0, 0, 0, 0, 768]

# HMAC of a digest given as 8 words, as 8 words: one block each side.
def mac.words(m: Mac, u: List<&2, U32>) -> List<&2, U32>:
  match m:
    case Mac{inner, outer}:
      sha.words(sha.compress(outer, List.append(&2, U32,
        sha.words(sha.compress(inner, List.append(&2, U32, u, mac.pad32()))), mac.pad32())))

# ---- PBKDF2-HMAC-SHA-256 (RFC 8018), one 32-byte block: what SCRAM needs

def pbkdf2.go(n: Nat, +m: Mac, +u: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      +next = mac.words(m, u)
      pbkdf2.go(p, m, next, xor(acc, next))

def pbkdf2(+password: List<&2, U32>, salt: List<&2, U32>, iterations: Nat) -> List<&2, U32>:
  +m = mac.key(password)
  +u = sha.words(mac.with(m, List.append(&2, U32, salt, [0, 0, 0, 1])))
  bytes.be(pbkdf2.go(Nat.sub(iterations, 1n), m, u, u))

# ---- MD5 (RFC 1321)

type Md5 is Data:
  Md5{a: U32, b: U32, c: U32, d: U32}

# A step: its constant, round (which function), message word, and the
# rotation as left and right shifts.
type Md is Data:
  Md{k: U32, round: U32, g: Nat, l: Nat, r: Nat}

def md5.table() -> List<&2, Md>:
  [
  Md{3614090360, 0, 0n, 7n, 25n}, Md{3905402710, 0, 1n, 12n, 20n}, Md{606105819, 0, 2n, 17n, 15n}, Md{3250441966, 0, 3n, 22n, 10n},
  Md{4118548399, 0, 4n, 7n, 25n}, Md{1200080426, 0, 5n, 12n, 20n}, Md{2821735955, 0, 6n, 17n, 15n}, Md{4249261313, 0, 7n, 22n, 10n},
  Md{1770035416, 0, 8n, 7n, 25n}, Md{2336552879, 0, 9n, 12n, 20n}, Md{4294925233, 0, 10n, 17n, 15n}, Md{2304563134, 0, 11n, 22n, 10n},
  Md{1804603682, 0, 12n, 7n, 25n}, Md{4254626195, 0, 13n, 12n, 20n}, Md{2792965006, 0, 14n, 17n, 15n}, Md{1236535329, 0, 15n, 22n, 10n},
  Md{4129170786, 1, 1n, 5n, 27n}, Md{3225465664, 1, 6n, 9n, 23n}, Md{643717713, 1, 11n, 14n, 18n}, Md{3921069994, 1, 0n, 20n, 12n},
  Md{3593408605, 1, 5n, 5n, 27n}, Md{38016083, 1, 10n, 9n, 23n}, Md{3634488961, 1, 15n, 14n, 18n}, Md{3889429448, 1, 4n, 20n, 12n},
  Md{568446438, 1, 9n, 5n, 27n}, Md{3275163606, 1, 14n, 9n, 23n}, Md{4107603335, 1, 3n, 14n, 18n}, Md{1163531501, 1, 8n, 20n, 12n},
  Md{2850285829, 1, 13n, 5n, 27n}, Md{4243563512, 1, 2n, 9n, 23n}, Md{1735328473, 1, 7n, 14n, 18n}, Md{2368359562, 1, 12n, 20n, 12n},
  Md{4294588738, 2, 5n, 4n, 28n}, Md{2272392833, 2, 8n, 11n, 21n}, Md{1839030562, 2, 11n, 16n, 16n}, Md{4259657740, 2, 14n, 23n, 9n},
  Md{2763975236, 2, 1n, 4n, 28n}, Md{1272893353, 2, 4n, 11n, 21n}, Md{4139469664, 2, 7n, 16n, 16n}, Md{3200236656, 2, 10n, 23n, 9n},
  Md{681279174, 2, 13n, 4n, 28n}, Md{3936430074, 2, 0n, 11n, 21n}, Md{3572445317, 2, 3n, 16n, 16n}, Md{76029189, 2, 6n, 23n, 9n},
  Md{3654602809, 2, 9n, 4n, 28n}, Md{3873151461, 2, 12n, 11n, 21n}, Md{530742520, 2, 15n, 16n, 16n}, Md{3299628645, 2, 2n, 23n, 9n},
  Md{4096336452, 3, 0n, 6n, 26n}, Md{1126891415, 3, 7n, 10n, 22n}, Md{2878612391, 3, 14n, 15n, 17n}, Md{4237533241, 3, 5n, 21n, 11n},
  Md{1700485571, 3, 12n, 6n, 26n}, Md{2399980690, 3, 3n, 10n, 22n}, Md{4293915773, 3, 10n, 15n, 17n}, Md{2240044497, 3, 1n, 21n, 11n},
  Md{1873313359, 3, 8n, 6n, 26n}, Md{4264355552, 3, 15n, 10n, 22n}, Md{2734768916, 3, 6n, 15n, 17n}, Md{1309151649, 3, 13n, 21n, 11n},
  Md{4149444226, 3, 4n, 6n, 26n}, Md{3174756917, 3, 11n, 10n, 22n}, Md{718787259, 3, 2n, 15n, 17n}, Md{3951481745, 3, 9n, 21n, 11n}]

def md5.f(+round: U32, +b: U32, +c: U32, +d: U32) -> U32:
  match round:
    case 0:
      ((b .&. c) .|. (U32.not(b) .&. d) : U32)
    case 1:
      ((d .&. b) .|. (U32.not(d) .&. c) : U32)
    case 2:
      (b .^. (c .^. d) : U32)
    case _:
      (c .^. (b .|. U32.not(d)) : U32)

def md5.step(st: Md5, s: Md, +m: List<&2, U32>) -> Md5:
  match st s:
    case Md5{a, +b, +c, +d} Md{k, round, g, l, r}:
      +f = (md5.f(round, b, c, d) + a + k + nth(m, g) : U32)
      Md5{d, (b + ((f << l) .|. (f >> r)) : U32), b, c}

def md5.steps(ss: List<&2, Md>, st: Md5, +m: List<&2, U32>) -> Md5:
  match ss:
    case Nil{}:
      st
    case s <> rest:
      md5.steps(rest, md5.step(st, s, m), m)

def md5.add(x: Md5, y: Md5) -> Md5:
  match x y:
    case Md5{a, b, c, d} Md5{a2, b2, c2, d2}:
      Md5{(a + a2 : U32), (b + b2 : U32), (c + c2 : U32), (d + d2 : U32)}

def md5.blocks(n: Nat, +st: Md5, +ws: List<&2, U32>) -> Md5:
  match n:
    case 0n:
      st
    case 1n+p:
      md5.blocks(p, md5.add(st, md5.steps(md5.table(), st, List.take(&2, U32, ws, 16n))),
        List.drop(&2, U32, ws, 16n))

def md5.bytes(st: Md5) -> List<&2, U32>:
  match st:
    case Md5{a, b, c, d}:
      bytes.le([a, b, c, d])

def md5(+bytes: List<&2, U32>) -> List<&2, U32>:
  +total = U32.from_nat(List.length(&2, U32, bytes))
  +padded = List.append(&2, U32, bytes, pad(total,
    List.append(&2, U32, le32((total << 3n : U32)), le32((total >> 29n : U32)))))
  md5.bytes(md5.blocks(blocks.count(padded), Md5{1732584193, 4023233417, 2562383102, 271733878},
    words.le(padded)))

# ---- hex and base64 (RFC 4648)

def hex.digit(+d: U32) -> U32:
  Bool.pick(U32, U32.is_lt(d, 10), (d + 48 : U32), (d + 87 : U32))

# Lowercase hex digits, as ASCII bytes.
def hex(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      hex.digit((h >> 4n : U32)) <> hex.digit((h .&. 15 : U32)) <> hex(t)

def b64.char(+v: U32) -> U32:
  Bool.pick(U32, U32.is_lt(v, 26), (v + 65 : U32),
    Bool.pick(U32, U32.is_lt(v, 52), (v + 71 : U32),
      Bool.pick(U32, U32.is_lt(v, 62), (v - 4 : U32),
        Bool.pick(U32, U32.is_eq(v, 62), 43, 47))))

def base64(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case +a <> +b <> +c <> rest:
      List.append(&2, U32, [b64.char((a >> 2n : U32)), b64.char((((a .&. 3) << 4n) .|. (b >> 4n) : U32)),
        b64.char((((b .&. 15) << 2n) .|. (c >> 6n) : U32)), b64.char((c .&. 63 : U32))], base64(rest))
    case +a <> +b <> Nil{}:
      [b64.char((a >> 2n : U32)), b64.char((((a .&. 3) << 4n) .|. (b >> 4n) : U32)),
        b64.char(((b .&. 15) << 2n : U32)), 61]
    case +a <> Nil{}:
      [b64.char((a >> 2n : U32)), b64.char(((a .&. 3) << 4n : U32)), 61, 61]
    case Nil{}:
      Nil{}

def b64.value(+c: U32) -> U32:
  Bool.pick(U32, U32.is_eq(c, 43), 62,
    Bool.pick(U32, U32.is_eq(c, 47), 63,
      Bool.pick(U32, U32.is_lt(c, 58), (c + 4 : U32),
        Bool.pick(U32, U32.is_lt(c, 91), (c - 65 : U32), (c - 71 : U32)))))

def b64.values(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      match h:
        case 61:
          b64.values(t)
        case _:
          b64.value(h) <> b64.values(t)

def b64.bytes(vs: List<&2, U32>) -> List<&2, U32>:
  match vs:
    case +a <> +b <> +c <> d <> rest:
      List.append(&2, U32, [(((a << 2n) .|. (b >> 4n)) .&. 255 : U32),
        (((b << 4n) .|. (c >> 2n)) .&. 255 : U32), (((c << 6n) .|. d) .&. 255 : U32)], b64.bytes(rest))
    case +a <> +b <> +c <> Nil{}:
      [(((a << 2n) .|. (b >> 4n)) .&. 255 : U32), (((b << 4n) .|. (c >> 2n)) .&. 255 : U32)]
    case +a <> +b <> Nil{}:
      [(((a << 2n) .|. (b >> 4n)) .&. 255 : U32)]
    case _:
      Nil{}

def unbase64(xs: List<&2, U32>) -> List<&2, U32>:
  b64.bytes(b64.values(xs))
