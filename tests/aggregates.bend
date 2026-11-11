# Blink against the database's own arithmetic. Fetches 100,000 generated
# rows of mixed types (int4, UTF-8 text with NULLs and empty strings, bool,
# int2 with NULLs, date, numeric), once as one simple query and once through
# the extended protocol in batches of 1000 with a parameter, and computes
# aggregates from the decoded values: counts, sums, and an MD5 of every
# value as Postgres prints it, in order. Then asks Postgres for the same
# aggregates in SQL. Prints three lines that must be identical, and
# scripts/test.sh checks them against psql's answer too.
#
#   bend tests/aggregates.bend          the three lines
#   bend tests/aggregates.bend --sql    the aggregate SQL, for psql
import Base
import ../blink/bytes.bend as B
import ../blink/crypto.bend as C
import ../blink/rows.bend as R
import ../blink/session.bend as S
import ../blink/io.bend as Blink

def data() -> String:
  "WITH d AS (SELECT g AS id, (g * 7919 % 65536 - 32768)::int4 AS i, " ++
  "CASE g % 5 WHEN 0 THEN NULL WHEN 1 THEN 'héllo ' || g WHEN 2 THEN '🐘' WHEN 3 THEN '' " ++
  "ELSE repeat('ab', g % 50) END AS t, g % 3 = 0 AS b, " ++
  "CASE WHEN g % 7 = 0 THEN NULL ELSE (g % 32767)::int2 END AS s, " ++
  "'2026-01-01'::date + g % 1000 AS d, (g / 7.0)::numeric(14,4) AS n " ++
  "FROM generate_series(1, 100000) g) "

def rows() -> String:
  data() ++ "SELECT id, i, t, b, s, d, n FROM d WHERE id > $1::int4 ORDER BY id"

def simple() -> String:
  data() ++ "SELECT id, i, t, b, s, d, n FROM d ORDER BY id"

# Sums mod 2^32, as Blink's U32 sums wrap.
def aggregates() -> String:
  data() ++ "SELECT count(*), count(t), count(s), count(*) FILTER (WHERE b), " ++
  "sum(id) % 4294967296, (sum(i) % 4294967296 + 4294967296) % 4294967296, " ++
  "sum(octet_length(t)), sum(s), " ++
  "md5(string_agg(concat_ws(',', id, i, coalesce(t, '∅'), b, coalesce(s::text, '∅'), d, n), '|' ORDER BY id)) FROM d"

# ---- aggregating decoded rows

type Agg is Data:
  Agg{rows: U32, ts: U32, ss: U32, bs: U32, ids: U32, isum: U32, octets: U32, s: U32,
    bad: U32, lines: List<&2, List<&2, U32>>}

# A value as Postgres's text output writes it; NULL is ∅.
def render(v: R.Value) -> List<&2, U32>:
  match v:
    case R.Value.Null{}:
      B.utf8("∅")
    case R.Value.Bool{True{}}:
      [116]
    case R.Value.Bool{False{}}:
      [102]
    case R.Value.Int{R.Int{True{}, abs}}:
      45 <> B.utf8(U32.show(abs))
    case R.Value.Int{R.Int{False{}, abs}}:
      B.utf8(U32.show(abs))
    case R.Value.Text{bytes}:
      Bytes.to_list(bytes)

def line(es: List<&2, R.Entry>) -> List<&2, U32>:
  match es:
    case Nil{}:
      Nil{}
    case R.Entry{n, v} <> Nil{}:
      render(v)
    case R.Entry{n, v} <> rest:
      List.append(&2, U32, render(v), 44 <> line(rest))

def signed(+acc: U32, v: R.Value) -> U32:
  match v:
    case R.Value.Int{R.Int{True{}, abs}}:
      (acc - abs : U32)
    case R.Value.Int{R.Int{False{}, abs}}:
      (acc + abs : U32)
    case _:
      acc

def some(v: R.Value) -> U32:
  match v:
    case R.Value.Null{}:
      0
    case _:
      1

def truth(v: R.Value) -> U32:
  match v:
    case R.Value.Bool{True{}}:
      1
    case _:
      0

def octets(v: R.Value) -> U32:
  match v:
    case R.Value.Text{bytes}:
      U32.from_nat(Bytes.length(bytes))
    case _:
      0

def row(a: Agg, +es: List<&2, R.Entry>) -> Agg:
  match a es:
    case Agg{rows, ts, ss, bs, ids, isum, os, s, bad, lines}
      R.Entry{_, +id} <> R.Entry{_, +i} <> R.Entry{_, +t} <> R.Entry{_, +b} <> R.Entry{_, +sv} <> R.Entry{_, d} <> R.Entry{_, n} <> Nil{}:
      Agg{(rows + 1 : U32), (ts + some(t) : U32), (ss + some(sv) : U32), (bs + truth(b) : U32),
        signed(ids, id), signed(isum, i), (os + octets(t) : U32), signed(s, sv), bad, line(es) <> lines}
    case Agg{rows, ts, ss, bs, ids, isum, os, s, bad, lines} _:
      Agg{rows, ts, ss, bs, ids, isum, os, s, (bad + 1 : U32), lines}

def step(a: Agg, r: S.Reply) -> Agg:
  match r:
    case S.Reply.Row{es}:
      row(a, es)
    case _:
      a

def joined(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> Nil{}:
      l
    case l <> rest:
      List.append(&2, U32, l, 124 <> joined(rest))

# The aggregates as psql -A prints the SQL ones, or what went wrong.
def show(a: Agg) -> String:
  match a:
    case Agg{rows, ts, ss, bs, ids, isum, os, s, +bad, lines}:
      match bad:
        case 0:
          U32.show(rows) ++ "|" ++ U32.show(ts) ++ "|" ++ U32.show(ss) ++ "|" ++ U32.show(bs) ++ "|" ++
          U32.show(ids) ++ "|" ++ U32.show(isum) ++ "|" ++ U32.show(os) ++ "|" ++ U32.show(s) ++ "|" ++
          B.text(C.hex(C.md5(joined(List.reverse(&2, List<&2, U32>, lines)))))
        case _:
          U32.show(bad) ++ " rows not shaped (int4, int4, text, bool, int2, date, numeric)"

def problems(r: S.Reply) -> IO(Unit):
  match r:
    case S.Reply.Error{severity, code, message}:
      IO.print_err(code ++ ": " ++ message)
    case S.Reply.Closed{reason}:
      IO.print_err("closed: " ++ reason)
    case S.Reply.Refused{reason}:
      IO.print_err("refused: " ++ reason)
    case _:
      IO.pure(Unit, Unit{})

def report(name: String, +rs: List<&2, S.Reply>) -> IO(Unit):
  do IO<Unit>:
    List.for_each(~&2, ~S.Reply, ~(r => problems(r)), rs)
    IO.print(name ++ show(List.foldl(~&2, ~S.Reply, ~Agg, ~(a => r => step(a, r)), rs,
      Agg{0, 0, 0, 0, 0, 0, 0, 0, 0, Nil{}})))

def answer(r: S.Reply) -> IO(Unit):
  match r:
    case S.Reply.Row{es}:
      IO.print("postgres         " ++ R.show(es))
    case _:
      problems(r)

def env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return Result.default(&1, &1, U32 & String, String, r, d)

def check() -> IO(Unit):
  do IO<Unit>:
    +host : String <- env("PGHOST", "127.0.0.1")
    p : String <- env("PGPORT", "5432")
    +port : U32 = Maybe.default(&2, U32, U32.read(p), 5432)
    +user : String <- env("PGUSER", "postgres")
    +pw : String <- env("PGPASSWORD", "")
    +db : String <- env("PGDATABASE", user)
    a : List<&2, S.Reply> <- Blink.run(host, port, user, pw, db, [S.Query.Simple{simple()}])
    report("blink, simple    ", a)
    b : List<&2, S.Reply> <- Blink.run(host, port, user, pw, db,
      [S.Query.Extended{rows(), [Some{"0"}], 1000, 0}])
    report("blink, batched   ", b)
    c : List<&2, S.Reply> <- Blink.run(host, port, user, pw, db, [S.Query.Simple{aggregates()}])
    List.for_each(~&2, ~S.Reply, ~(r => answer(r)), c)

def mode(args: List<String>) -> IO(Unit):
  match args:
    case prog <> flag <> rest:
      IO.print(aggregates())
    case _:
      check()

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    mode(args)
