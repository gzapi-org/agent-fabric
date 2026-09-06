#!/usr/bin/env bash
# tools/moveto/test_moveto.sh
#
# Behavioural tests for moveto's target resolution — the half that can be
# tested without spawning an interactive shell. `--print` exists for exactly
# this: it runs the whole resolution path and stops before the exec.
#
# What is asserted, and why each earned a test:
#
#   1. the template layout (~/projects/<account>) resolves, and the title is
#      the ROLE INSTANCE — the account name, not the clone, not the role
#   2. an account holding several clones refuses to guess, lists them, exits 1
#   3. ...and with a clone named explicitly, resolves it and titles by CLONE,
#      because the account name cannot tell two of its sessions apart
#   4. an account with an empty projects dir says "not provisioned", rather
#      than silently dropping the caller into $HOME
#   5. an unknown account and an unknown clone both fail loudly
#
# `getent` and `sudo` are mocked on PATH: the fixture accounts do not exist,
# and the test must not require root. The sudo mock strips its own flags and
# runs the rest as the current user, so the code path under test is the real
# one — the same branch a genuine cross-account call takes.
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed

set -uo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )"
UNDER_TEST="$SCRIPT_DIR/moveto"

[[ -f "$UNDER_TEST" ]] || { echo "test: $UNDER_TEST not found" >&2; exit 1; }

failures=0
SANDBOX=""
cleanup() { [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

SANDBOX="$(mktemp -d)"
BIN="$SANDBOX/bin"; mkdir -p "$BIN"

# Fixture accounts. `solo` follows the template; `many` holds three clones;
# `empty` is provisioned but has no clone yet.
mkdir -p "$SANDBOX/home/solo/projects/solo"
mkdir -p "$SANDBOX/home/many/projects/"{alpha,beta,gamma}
mkdir -p "$SANDBOX/home/empty/projects"
# `odd` is the fixture that distinguishes "title = account" from "title =
# clone": one clone, named differently from the account. Without it a mutant
# that always titles by clone basename passes every other assertion, because
# the template layout makes the two identical.
mkdir -p "$SANDBOX/home/odd/projects/weird-name"

cat > "$BIN/getent" <<EOF
#!/usr/bin/env bash
# Only the two forms moveto uses: a lookup, and a full dump for --list.
if [[ "\$1" == "passwd" && \$# -eq 2 ]]; then
    case "\$2" in
        solo|many|empty|odd) echo "\$2:x:2000:2000::$SANDBOX/home/\$2:/bin/bash"; exit 0 ;;
        *) exit 2 ;;
    esac
fi
if [[ "\$1" == "passwd" && \$# -eq 1 ]]; then
    for u in solo many empty odd; do
        echo "\$u:x:2000:2000::$SANDBOX/home/\$u:/bin/bash"
    done
    exit 0
fi
exit 2
EOF

cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
# Strip sudo's own flags, then run the rest as the current user. The point is
# to exercise moveto's cross-account branch without needing root.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|-H) shift ;;
        -u) shift 2 ;;
        *) break ;;
    esac
done
exec "$@"
EOF
chmod 755 "$BIN/getent" "$BIN/sudo"
export PATH="$BIN:$PATH"

check() { # check <label> <expected-substring> <actual>
    if [[ "$3" == *"$2"* ]]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s\n       want substring: %s\n       got: %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}
check_status() { # check_status <label> <expected> <actual>
    if [[ "$3" == "$2" ]]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s: expected exit %s, got %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}

echo "1. template layout resolves, title is the role instance"
out=$("$UNDER_TEST" solo --print 2>&1); st=$?
check_status "exits 0" 0 "$st"
check "resolves ~/projects/<account>" "/home/solo/projects/solo" "$out"
check "title is the account, not the clone path" "title: solo" "$out"

echo "1b. single clone named differently: still titled by ACCOUNT"
out=$("$UNDER_TEST" odd --print 2>&1); st=$?
check_status "exits 0" 0 "$st"
check "falls back to the only clone" "/home/odd/projects/weird-name" "$out"
check "title is the account, NOT the clone name" "title: odd" "$out"

echo "2. several clones: refuses to guess"
out=$("$UNDER_TEST" many --print 2>&1); st=$?
check_status "exits 1" 1 "$st"
check "says how many" "many has 3 clones" "$out"
check "lists them" "beta" "$out"

echo "3. several clones, one named: resolves and titles by clone"
out=$("$UNDER_TEST" many beta --print 2>&1); st=$?
check_status "exits 0" 0 "$st"
check "resolves the named clone" "/home/many/projects/beta" "$out"
check "title is the clone, since the account cannot distinguish" "title: beta" "$out"

echo "4. provisioned but no clone yet"
out=$("$UNDER_TEST" empty --print 2>&1); st=$?
check_status "exits 1" 1 "$st"
check "says not provisioned rather than falling back to \$HOME" "has no clone yet" "$out"

echo "5. unknown account and unknown clone fail loudly"
out=$("$UNDER_TEST" nosuchuser --print 2>&1); st=$?
check_status "unknown account exits 1" 1 "$st"
check "names the account" "no such account: nosuchuser" "$out"
out=$("$UNDER_TEST" solo nosuchclone --print 2>&1); st=$?
check_status "unknown clone exits 1" 1 "$st"
check "names the path" "no such directory" "$out"

echo "6. --list shows accounts that have clones"
out=$("$UNDER_TEST" --list 2>&1); st=$?
check_status "exits 0" 0 "$st"
check "lists the template account" "solo" "$out"
check "lists a multi-clone account's clones" "gamma" "$out"
check "omits an account with no clones" "" "${out/empty/}"

echo
if [[ $failures -eq 0 ]]; then
    echo "test_moveto: all assertions passed"
    exit 0
fi
echo "test_moveto: $failures assertion(s) failed"
exit 1
