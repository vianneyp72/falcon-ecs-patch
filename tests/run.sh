#!/usr/bin/env bash
# Offline tests: argument handling and exit codes. No AWS or Docker needed.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/falcon-ecs-patch.sh"
fail=0

check() { # name expected_rc actual_rc
  if [ "$2" -eq "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (expected $2, got $3)"; fail=1; fi
}

"$SCRIPT" --version >/dev/null 2>&1;                               check "version" 0 $?
"$SCRIPT" --help >/dev/null 2>&1;                                  check "help" 0 $?
"$SCRIPT" bogus >/dev/null 2>&1;                                   check "unknown command" 2 $?
env -u AWS_REGION -u AWS_DEFAULT_REGION "$SCRIPT" audit --cluster c >/dev/null 2>&1; check "missing region" 2 $?
"$SCRIPT" audit --region us-east-1 >/dev/null 2>&1;                check "audit needs cluster" 2 $?
"$SCRIPT" audit --cluster c --region us-east-1 --client-secret x >/dev/null 2>&1; check "client secret flag rejected" 2 $?
"$SCRIPT" patch --region us-east-1 --cid x >/dev/null 2>&1;         check "patch needs a target" 2 $?
"$SCRIPT" patch --region us-east-1 --cid x --file a.json --family f >/dev/null 2>&1; check "file and family are exclusive" 2 $?
"$SCRIPT" patch --region us-east-1 --cid x --file a.json --deploy >/dev/null 2>&1; check "file rejects deploy" 2 $?
"$SCRIPT" patch --region us-east-1 --cid x --family f --from-revision 1 >/dev/null 2>&1; check "from-revision needs service" 2 $?
"$SCRIPT" patch --region us-east-1 --cid x --family f --output o.json >/dev/null 2>&1; check "output needs file" 2 $?

exit "$fail"
