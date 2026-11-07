# Using Blink as a library: run queries, then match the replies by shape
# and fold over them. Makes its own temporary table, so any database works.
# Connects as examples/query.bend does (PGHOST, PGUSER, PGPASSWORD,
# PGDATABASE).
#
#   bend examples/cities.bend
#   # Tokyo has 13960000 people
#   # São Paulo has 12330000 people
#   # Zürich has 421878 people
#   # total: 26711878
import Base
import ../blink/io.bend as Blink
import ../blink/session.bend as S
import ../blink/rows.bend as R

def env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return Result.default(&1, &1, U32 & String, String, r, d)

# A (text, int4) row: name the values by matching the record.
def line(r: S.Reply) -> IO(Unit):
  match r:
    case S.Reply.Row{R.Entry{n, R.Value.Text{name}} <> R.Entry{p, R.Value.Int{R.Int{neg, pop}}} <> rest}:
      IO.print(name ++ " has " ++ U32.show(pop) ++ " people")
    case S.Reply.Error{severity, code, message}:
      IO.print_err(code ++ ": " ++ message)
    case S.Reply.Closed{reason}:
      IO.print_err("closed: " ++ reason)
    case _:
      IO.pure(Unit, Unit{})

def total(acc: U32, r: S.Reply) -> U32:
  match r:
    case S.Reply.Row{R.Entry{n, R.Value.Text{name}} <> R.Entry{p, R.Value.Int{R.Int{neg, pop}}} <> rest}:
      (acc + pop : U32)
    case _:
      acc

def main() -> IO(Unit):
  do IO<Unit>:
    host : String <- env("PGHOST", "127.0.0.1")
    +user : String <- env("PGUSER", "postgres")
    pw : String <- env("PGPASSWORD", "")
    db : String <- env("PGDATABASE", user)
    +rs : List<&2, S.Reply> <- Blink.run(host, 5432, user, pw, db, [
      "CREATE TEMP TABLE city (name text, pop int4)",
      "INSERT INTO city VALUES ('Tokyo', 13960000), ('São Paulo', 12330000), ('Zürich', 421878), ('Atlantis', NULL)",
      "SELECT name, pop FROM city WHERE pop IS NOT NULL ORDER BY pop DESC"])
    List.for_each(~&2, ~S.Reply, ~(r => line(r)), rs)
    IO.print("total: " ++ U32.show(List.foldl(~&2, ~S.Reply, ~U32, ~(a => r => total(a, r)), rs, 0)))
