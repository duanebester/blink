# Runs each argument as a query and prints the rows as `psql -qAt` does:
# values joined by "|", NULL empty. Errors go to stderr, and the exit code
# is 1 if there was any. With --replies, prints every reply instead.
# --fetch N, --timeout MS, --param V and --null run the queries after them
# through the extended protocol (one statement each): rows N at a time,
# cancelled if the server is silent for MS ms, and V (or NULL) as the next
# query's next $n.
# Connects as libpq would, from PGHOST (an IPv4 address, 127.0.0.1 by
# default), PGPORT (5432), PGUSER ($USER), PGPASSWORD and PGDATABASE (the
# user).
#
#   bend examples/query.bend "SELECT 1 AS one"
#   bend examples/query.bend -- --param 41 "SELECT \$1::int4 + 1"
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
    case S.Reply.Cancelled{}:
      IO.print_err("cancelled")
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
    case S.Reply.Cancelled{}:
      True{}
    case S.Reply.Closed{reason}:
      True{}
    case _:
      False{}

# ---- the command line, folded into Opts. Flags apply to the SQL after
# them; params to the next SQL only. want is the flag whose value comes
# next: 2 --fetch, 3 --timeout, 4 --param. params and qs are newest-first.
type Opts is Data:
  Opts{every: Bool, ext: Bool, fetch: U32, timeout: U32, params: List<&2, Maybe<&2, String>>,
    qs: List<&2, S.Query>, want: U32}

def flag(+a: String) -> U32:
  Bool.pick(U32, String.eq(a, "--replies"), 1, Bool.pick(U32, String.eq(a, "--fetch"), 2,
    Bool.pick(U32, String.eq(a, "--timeout"), 3, Bool.pick(U32, String.eq(a, "--param"), 4,
      Bool.pick(U32, String.eq(a, "--null"), 5, 0)))))

def query(+ext: Bool, sql: String, params: List<&2, Maybe<&2, String>>, fetch: U32,
  timeout: U32) -> S.Query:
  match ext:
    case True{}:
      S.Query.Extended{sql, List.reverse(&2, Maybe<&2, String>, params), fetch, timeout}
    case False{}:
      S.Query.Simple{sql}

def word(+code: U32, a: String, o: Opts) -> Opts:
  match code:
    case 0:
      match o:
        case Opts{every, +ext, +fetch, +timeout, params, qs, want}:
          Opts{every, ext, fetch, timeout, Nil{}, query(ext, a, params, fetch, timeout) <> qs, 0}
    case 1:
      match o:
        case Opts{every, ext, fetch, timeout, params, qs, want}:
          Opts{True{}, ext, fetch, timeout, params, qs, 0}
    case 5:
      match o:
        case Opts{every, ext, fetch, timeout, params, qs, want}:
          Opts{every, True{}, fetch, timeout, None{} <> params, qs, 0}
    case _:
      match o:
        case Opts{every, ext, fetch, timeout, params, qs, want}:
          Opts{every, True{}, fetch, timeout, params, qs, code}

def number(a: String) -> U32:
  Maybe.default(&2, U32, U32.read(a), 0)

def step(o: Opts, +a: String) -> Opts:
  match o:
    case Opts{every, ext, fetch, timeout, params, qs, +want}:
      match want:
        case 2:
          Opts{every, ext, number(a), timeout, params, qs, 0}
        case 3:
          Opts{every, ext, fetch, number(a), params, qs, 0}
        case 4:
          Opts{every, ext, fetch, timeout, Some{a} <> params, qs, 0}
        case _:
          word(flag(a), a, Opts{every, ext, fetch, timeout, params, qs, 0})

def go(every: Bool, +qs: List<&2, S.Query>) -> IO(Unit):
  do IO<Unit>:
    user : String <- env("USER", "postgres")
    +pguser : String <- env("PGUSER", user)
    pw   : String <- env("PGPASSWORD", "")
    db   : String <- env("PGDATABASE", pguser)
    host : String <- env("PGHOST", "127.0.0.1")
    p    : String <- env("PGPORT", "5432")
    +rs  : List<&2, S.Reply> <- Blink.run(host, Maybe.default(&2, U32, U32.read(p), 5432), pguser, pw, db, qs)
    print_all(every, rs)
    IO.exit(Bool.pick(U32, List.any(~&2, ~S.Reply, ~(r => failed(r)), rs), 1, 0))

def run(o: Opts) -> IO(Unit):
  match o:
    case Opts{every, ext, fetch, timeout, params, qs, want}:
      match qs:
        case Nil{}:
          IO.print_err("usage: query [--replies] [--fetch N] [--timeout MS] [--param V | --null]... SQL...")
        case q <> rest:
          go(every, List.reverse(&2, S.Query, q <> rest))

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
    run(List.foldl(~&2, ~String, ~Opts, ~(o => a => step(o, a)), List.drop(&2, String, strings(args), 1n),
      Opts{False{}, False{}, 0, 0, Nil{}, Nil{}, 0}))
