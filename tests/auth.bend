# Known-answer vectors for blink/crypto.bend and blink/auth.bend, from the
# RFCs and FIPS that define each function. No server needed.
# tests/auth.expected is what it must print.
import Base
import ../blink/bytes.bend as B
import ../blink/crypto.bend as C
import ../blink/auth.bend as A

def proof(p: A.Proof) -> String:
  match p:
    case A.Proof{final, signature, ok}:
      B.text(final) ++ "\nscram sig   " ++ B.text(signature) ++ Bool.pick(String, ok, "", " (bad nonce)")

def hex(xs: List<&2, U32>) -> String:
  B.text(C.hex(xs))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("md5 ''      " ++ hex(C.md5(B.utf8(""))))
    IO.print("md5 fox     " ++ hex(C.md5(B.utf8("The quick brown fox jumps over the lazy dog"))))
    IO.print("md5 80      " ++ hex(C.md5(B.utf8("12345678901234567890123456789012345678901234567890123456789012345678901234567890"))))
    IO.print("sha256 ''   " ++ hex(C.sha256(B.utf8(""))))
    IO.print("sha256 abc  " ++ hex(C.sha256(B.utf8("abc"))))
    IO.print("sha256 448  " ++ hex(C.sha256(B.utf8("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))))
    IO.print("hmac jefe   " ++ hex(C.hmac(B.utf8("Jefe"), B.utf8("what do ya want for nothing?"))))
    IO.print("hmac 131    " ++ hex(C.hmac(List.replicate(U32, 131n, 170), B.utf8("Test Using Larger Than Block-Size Key - Hash Key First"))))
    IO.print("pbkdf2 1    " ++ hex(C.pbkdf2(B.utf8("password"), B.utf8("salt"), 1n)))
    IO.print("pbkdf2 4096 " ++ hex(C.pbkdf2(B.utf8("password"), B.utf8("salt"), 4096n)))
    IO.print("base64      " ++ B.text(C.base64(B.utf8("f"))) ++ " " ++ B.text(C.base64(B.utf8("fo"))) ++ " " ++ B.text(C.base64(B.utf8("foobar"))))
    IO.print("unbase64    " ++ B.text(C.unbase64(B.utf8("Zm9vYg=="))) ++ " " ++ B.text(C.unbase64(B.utf8("Zm9vYmE="))) ++ " " ++ B.text(C.unbase64(B.utf8("Zm9vYmFy"))))
    IO.print("md5 pw      " ++ B.text(A.md5_password("banana", "md5y", [1, 2, 3, 4])))
    IO.print("scram final " ++ proof(A.scram.proof("pencil", B.utf8("n=user,r=rOprNGfwEbeRWgbNEkqO"),
      B.utf8("rOprNGfwEbeRWgbNEkqO"),
      B.utf8("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))))
