# Runs each argument as a query and prints the rows as `psql -qAt` does:
# values joined by "|", NULL empty. Errors go to stderr, and the exit code
# is 1 if there was any. With --replies first, prints every reply instead.
# Connects as libpq would, from PGHOST (an IPv4 address, 127.0.0.1 by
# default), PGPORT (5432), PGUSER ($USER) and PGDATABASE (the user).
#
#   bend examples/query.bend "SELECT 1 AS one"
import Base
import ../blink/rows.bend as R
import ../blink/session.bend as S
import ../blink/io.bend as Blink

def or_default(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      d

def env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return or_default(r, d)

def port(m: Maybe<&2, U32>) -> U32:
  match m:
    case None{}:
      5432
    case Some{p}:
      p

# a reply for a reader of psql's output: rows on stdout, failures on stderr
def print(r: S.Reply) -> IO(U32):
  match r:
    case S.Reply.Row{es}:
      do IO<U32>:
        IO.print(R.show(es))
        return 0
    case S.Reply.Error{severity, code, message}:
      do IO<U32>:
        IO.print_err(severity ++ " " ++ code ++ ": " ++ message)
        return 1
    case S.Reply.Closed{reason}:
      do IO<U32>:
        IO.print_err("closed: " ++ reason)
        return 1
    case _:
      IO.pure(U32, 0)

def bad(r: S.Reply) -> U32:
  match r:
    case S.Reply.Error{severity, code, message}:
      1
    case S.Reply.Closed{reason}:
      1
    case _:
      0

def print_all(every: Bool, rs: List<&2, S.Reply>, failed: U32) -> IO(U32):
  match every rs:
    case _ Nil{}:
      IO.pure(U32, failed)
    case True{} +r <> rest:
      do IO<U32>:
        IO.print(S.show(r))
        print_all(True{}, rest, U32.max(failed, bad(r)))
    case False{} r <> rest:
      do IO<U32>:
        b : U32 <- print(r)
        print_all(False{}, rest, U32.max(failed, b))

def go(every: Bool, queries: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    user : String <- env("USER", "postgres")
    +pguser : String <- env("PGUSER", user)
    db   : String <- env("PGDATABASE", pguser)
    host : String <- env("PGHOST", "127.0.0.1")
    p    : String <- env("PGPORT", "5432")
    rs   : List<&2, S.Reply> <- Blink.run(host, port(U32.read(p)), pguser, db, queries)
    failed : U32 <- print_all(every, rs, 0)
    IO.exit(failed)

def mode.flag(every: Bool, +a: String, rest: List<&2, String>) -> IO(Unit):
  match every:
    case True{}:
      go(True{}, rest)
    case False{}:
      go(False{}, a <> rest)

def mode(args: List<&2, String>) -> IO(Unit):
  match args:
    case Nil{}:
      IO.print_err("usage: query [--replies] SQL...")
    case +a <> rest:
      mode.flag(String.eq(a, "--replies"), a, rest)

# IO.args hands over a List<&1, String>; the session queue is Data.
def strings(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      h <> strings(t)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    mode(List.drop(&2, String, strings(args), 1n))
