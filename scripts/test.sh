#!/bin/sh
# Blink's tests, from the repo root or anywhere:
#
#   scripts/test.sh            proofs, replay (JS and native), live if reachable
#   BLINK_LIVE=1 scripts/test.sh   fail instead of skipping when no server
#
# The live part connects as libpq would, from PGHOST (default 127.0.0.1),
# PGPORT, PGUSER, PGPASSWORD and PGDATABASE, and compares Blink's rows with
# `psql -qAt` on the same queries. BLINK_AUTH="user:password ..." also logs
# in as each user, with its password and with a wrong one. BEND picks the
# bend command.
set -eu
cd "$(dirname "$0")/.."
BEND=${BEND:-bend}
export PGHOST="${PGHOST:-127.0.0.1}"
mkdir -p build
fails=0
pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# 1. the laws (pure, no server)
if out=$($BEND PROOF.bend 2>&1) && printf '%s\n' "$out" | grep -q '^ALL PROOFS CHECK'; then
  pass "laws: bend PROOF.bend"
else
  printf '%s\n' "$out"; fail "laws: bend PROOF.bend"
fi

# 2. a recorded session through the pure pipeline (no server), on both lanes
if $BEND tests/replay.bend | diff -u tests/replay.expected -; then
  pass "replay (JS lane)"
else
  fail "replay (JS lane)"
fi
if $BEND tests/replay.bend -o build/replay >/dev/null && ./build/replay | diff -u tests/replay.expected -; then
  pass "replay (native)"
else
  fail "replay (native)"
fi

# 3. hash, MAC and SCRAM vectors (no server), on both lanes
if $BEND tests/auth.bend | diff -u tests/auth.expected -; then
  pass "auth vectors (JS lane)"
else
  fail "auth vectors (JS lane)"
fi
if $BEND tests/auth.bend -o build/auth >/dev/null && ./build/auth | diff -u tests/auth.expected -; then
  pass "auth vectors (native)"
else
  fail "auth vectors (native)"
fi

# 4. a live server
$BEND examples/query.bend -o build/query >/dev/null
if ! ./build/query "SELECT 1" >/dev/null 2>&1; then
  if [ "${BLINK_LIVE:-0}" = 1 ]; then
    ./build/query "SELECT 1" || true
    fail "live: can't log in at $PGHOST:${PGPORT:-5432}"
  else
    printf 'skip  live: no server at %s:%s, or no login (see README)\n' "$PGHOST" "${PGPORT:-5432}"
  fi
else
  psql_each() { # sql...: psql -c for each
    n=$#
    while [ "$n" -gt 0 ]; do set -- "$@" -c "$1"; shift; n=$((n - 1)); done
    psql -X -qAt -v ON_ERROR_STOP=1 "$@"
  }
  same() { # name, sql...: Blink's stdout must equal psql's
    name=$1; shift
    if ! command -v psql >/dev/null 2>&1; then
      printf 'skip  live: %s (no psql to compare with)\n' "$name"; return
    fi
    # shellcheck disable=SC2086 # flags: Blink's own options, word-split
    if ./build/query $flags "$@" >build/blink.out && psql_each "$@" >build/psql.out \
      && diff -u build/psql.out build/blink.out >/dev/null; then
      pass "live: $name ($(wc -l <build/blink.out | tr -d ' ') rows, same as psql)"
    else
      diff -u build/psql.out build/blink.out | head -20; fail "live: $name"
    fi
  }
  flags=
  same "types and NULL" "SELECT 1::int4 AS one, 'héllo'::text AS t, NULL::text AS n, true AS b, -42 AS neg"
  same "edges" "SELECT (-2147483648)::int4, 32767::int2, 9223372036854775807::int8, 1.5::float8, '2026-11-07'::date, '\\x00ff'::bytea, ''::text"
  same "two statements" "SELECT 1 AS a; SELECT 'x' AS b, NULL AS c"
  same "two queries" "SELECT 'first'" "SELECT 'second'"
  same "10,000 rows" "SELECT g, 'city-' || g, g % 3 = 0 FROM generate_series(1, 10000) g"
  same "catalog" "SELECT * FROM pg_type ORDER BY oid LIMIT 100"
  same "COPY TO STDOUT" "COPY (SELECT g, 'héllo', NULL FROM generate_series(1, 3) g) TO STDOUT"
  flags="--fetch 333"
  same "10,000 rows, 333 at a time" "SELECT g, 'city-' || g, g % 3 = 0 FROM generate_series(1, 10000) g"
  flags=
  # shellcheck disable=SC2016 # $1 is Postgres's, not the shell's
  if [ "$(./build/query --param 41 --param 'héllo 🐘' --null --param "'); DROP TABLE x; --" \
    'SELECT $1::int4 + 1, $2::text, $3::text IS NULL, $4::text')" = "42|héllo 🐘|t|'); DROP TABLE x; --" ]; then
    pass "live: parameters, NULL and UTF-8, never spliced into the SQL"
  else
    fail "live: parameters"
  fi
  start=$(date +%s)
  if ./build/query --timeout 300 "SELECT pg_sleep(30)" "SELECT 'next'" >build/blink.out 2>build/blink.err; then
    fail "live: a cancelled query exits 1"
  elif [ $(($(date +%s) - start)) -lt 10 ] && grep -qx cancelled build/blink.err \
    && grep -q '^ERROR 57014' build/blink.err && grep -qx next build/blink.out; then
    pass "live: a timeout cancels the query on the server; the next one runs"
  else
    cat build/blink.err; fail "live: cancel"
  fi
  if timeout 30 ./build/query "CREATE TEMP TABLE c (x int)" "COPY c FROM STDIN" --fetch 2 "COPY c FROM STDIN" \
    "SELECT 'still runs'" >build/blink.out 2>build/blink.err; then
    fail "live: COPY FROM STDIN exits 1"
  elif [ "$(grep -c '^ERROR 57014: COPY from stdin failed' build/blink.err)" = 2 ] && grep -qx 'still runs' build/blink.out; then
    pass "live: COPY FROM STDIN fails, simple and extended; the next query runs"
  else
    cat build/blink.err; fail "live: COPY FROM STDIN"
  fi
  if ./build/query "SELECT 1/0" "SELECT 'still runs'" >build/blink.out 2>build/blink.err; then
    fail "live: an error exits 1"
  elif grep -q '22012: division by zero' build/blink.err && grep -qx 'still runs' build/blink.out; then
    pass "live: an error fails its query only, and exits 1"
  else
    cat build/blink.err; fail "live: an error fails its query only"
  fi
  if $BEND examples/query.bend "SELECT 'héllo' AS t, NULL AS n" | grep -qx 'héllo|'; then
    pass "live: JS lane"
  else
    fail "live: JS lane"
  fi
  for login in ${BLINK_AUTH:-}; do
    user=${login%%:*}
    if [ "$(PGUSER=$user PGPASSWORD=${login#*:} ./build/query "SELECT current_user" 2>&1)" = "$user" ] \
      && PGUSER=$user PGPASSWORD=not-the-password ./build/query "SELECT 1" 2>&1 | grep -q '^FATAL 28P01'; then
      pass "live: log in as $user; a wrong password fails"
    else
      fail "live: log in as $user"
    fi
  done
  # 100,000 rows of mixed types: Blink's own counts, sums and MD5 of every
  # value, simple and batched, must equal Postgres's and psql's.
  if $BEND tests/aggregates.bend -o build/aggregates >/dev/null && ./build/aggregates >build/agg.out \
    && want=$(./build/aggregates --sql | psql -X -qAt) && [ -n "$want" ] \
    && [ "$(cut -c18- build/agg.out | sort -u)" = "$want" ] && [ "$(wc -l <build/agg.out)" = 3 ]; then
    pass "live: aggregates over 100,000 rows match Postgres and psql"
  else
    cat build/agg.out; fail "live: aggregates"
  fi
  printf '%s\n' "Tokyo has 13960000 people" "São Paulo has 12330000 people" \
    "Zürich has 421878 people" "total: 26711878" >build/cities.expected
  if $BEND examples/cities.bend 2>&1 | diff -u build/cities.expected -; then
    pass "live: examples/cities.bend"
  else
    fail "live: examples/cities.bend"
  fi
fi

if [ "$fails" -ne 0 ]; then
  printf '%s failed\n' "$fails"; exit 1
fi
echo "all passed"
