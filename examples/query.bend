# Runs each argument as a query and prints the rows as `psql -qAt` does:
# values joined by "|", NULL empty. Errors go to stderr, and the exit code
# is 1 if there was any. With --replies first, prints every reply instead.
# Connects as libpq would, from PGHOST (an IPv4 address, 127.0.0.1 by
# default), PGPORT (5432), PGUSER ($USER), PGPASSWORD and PGDATABASE (the
# user).
#
#   bend examples/query.bend "SELECT 1 AS one"
import Base
import ../blink/rows.bend as R
import ../blink/session.bend as S
import ../blink/io.bend as Blink

def env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return Result.default(&1, &1, U32 & String, String, r, d)

# a reply for a reader of psql's output: rows on stdout, failures on stderr
def print(r: S.Reply) -> IO(Unit):
  match r:
    case S.Reply.Row{es}:
      IO.print(R.show(es))
    case S.Reply.Error{severity, code, message}:
      IO.print_err(severity ++ " " ++ code ++ ": " ++ message)
    case S.Reply.Closed{reason}:
      IO.print_err("closed: " ++ reason)
    case _:
      IO.pure(Unit, Unit{})

def print_all(every: Bool, rs: List<&2, S.Reply>) -> IO(Unit):
  match every:
    case True{}:
      List.for_each(~&2, ~S.Reply, ~(r => IO.print(S.show(r))), rs)
    case False{}:
      List.for_each(~&2, ~S.Reply, ~(r => print(r)), rs)

def failed(r: S.Reply) -> Bool:
  match r:
    case S.Reply.Error{severity, code, message}:
      True{}
    case S.Reply.Closed{reason}:
      True{}
    case _:
      False{}

def go(every: Bool, queries: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    user : String <- env("USER", "postgres")
    +pguser : String <- env("PGUSER", user)
    pw   : String <- env("PGPASSWORD", "")
    db   : String <- env("PGDATABASE", pguser)
    host : String <- env("PGHOST", "127.0.0.1")
    p    : String <- env("PGPORT", "5432")
    +rs  : List<&2, S.Reply> <- Blink.run(host, Maybe.default(&2, U32, U32.read(p), 5432), pguser, pw, db, queries)
    print_all(every, rs)
    IO.exit(Bool.pick(U32, List.any(~&2, ~S.Reply, ~(r => failed(r)), rs), 1, 0))

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
