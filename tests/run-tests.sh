#!/bin/sh
#
# Runs proton-firesafe through simulated weeks and months, with the stand-ins
# in tests/stubs for proton-drive, caffeinate, diskutil, msmtp and df.
# Prints TAP; exits non-zero if any test fails.
#
#   sh tests/run-tests.sh
#   TEST_SHELL=dash sh tests/run-tests.sh
#   TEST_SHELL="bash --posix" sh tests/run-tests.sh

set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../proton-firesafe"
TEST_SHELL=${TEST_SHELL:-sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/proton-firesafe-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

export TZ=UTC
export PROTON_FIRESAFE_PATH="$here/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export PROTON_FIRESAFE_CONFIG="$work/config"
export PROTON_FIRESAFE_STATE="$work/state"
export PROTON_FIRESAFE_LOG="$work/log"
export PROTON_FIRESAFE_VOLUMES="$work/Volumes"
export STUB_SHELF="$work/shelf"
export STUB_MAILBOX="$work/mailbox"
export STUB_CALLS="$work/calls"
V=$PROTON_FIRESAFE_VOLUMES

BASE=1793589420 # 2 November 2026, 03:17 UTC
DAY=86400
tests=0
failures=0

# ---- harness ------------------------------------------------------------------

ok() {
    tests=$((tests + 1))
    echo "ok $tests - $1"
}

not_ok() {
    tests=$((tests + 1))
    failures=$((failures + 1))
    echo "not ok $tests - $1"
}

check() {
    _desc=$1
    shift
    if "$@"; then ok "$_desc"; else not_ok "$_desc"; fi
}
refute() { ! "$@"; }
quietly() { "$@" >/dev/null 2>&1; }

# A fresh world: no disks, no state, no mail.
fresh() {
    echo "# $1"
    rm -rf "$work/state" "$work/log" "$work/Volumes" "$work/shelf" \
        "$work/mailbox" "$work/calls" "$work/list"
    mkdir -p "$V" "$STUB_SHELF"
    : >"$STUB_MAILBOX"
    cat >"$PROTON_FIRESAFE_CONFIG" <<EOF
MAILTO="backups@example.org"
SENDMAIL="msmtp -t"
PROTON_DRIVE=proton-drive
EOF
    marked=0
}

# day N [ARGS...]: run proton-firesafe on day N (which may be fractional
# via an hour offset: day 9 -1 means an hour before day 9).
day() {
    _n=$1
    shift
    _offset=0
    case ${1:-} in
    -[0-9]* | +[0-9]*)
        _offset=$(($1 * 3600))
        shift
        ;;
    esac
    # shellcheck disable=SC2086 # TEST_SHELL may carry options
    PROTON_FIRESAFE_NOW=$((BASE + _n * DAY + _offset)) $TEST_SHELL "$script" "$@"
}

# A newly formatted, encrypted, set-up disk, sitting on the shelf.
new_disk() {
    mkdir -p "$STUB_SHELF/$1"
    touch "$STUB_SHELF/$1/.proton-firesafe"
}
plug() { mv "$STUB_SHELF/$1" "$V/"; }
unplug() { mv "$V/$1" "$STUB_SHELF/"; }
where() { if [ -d "$V/$1" ]; then echo "$V/$1"; else echo "$STUB_SHELF/$1"; fi; }

# Complete takeouts on a disk, wherever it is.
takeouts_on() {
    find "$(where "$1")" -maxdepth 1 -type d -name 'takeout-*' ! -name '*.partial' |
        wc -l | tr -d ' '
}
partials_on() {
    find "$(where "$1")" -maxdepth 1 -name '*.partial' | wc -l | tr -d ' '
}
newest_on() {
    find "$(where "$1")" -maxdepth 1 -type d -name 'takeout-*' ! -name '*.partial' |
        sort | tail -n 1 | sed 's|.*/||'
}
stamp_of_day() { date -u -d "@$((BASE + $1 * DAY))" '+takeout-%Y%m%d-%H%M%S' 2>/dev/null ||
    date -u -r $((BASE + $1 * DAY)) '+takeout-%Y%m%d-%H%M%S'; }

mails() { grep -c '^Subject:' "$STUB_MAILBOX"; }
mark() { marked=$(mails); }
new_mails() { echo $(($(mails) - marked)); }
last_subject() { grep '^Subject:' "$STUB_MAILBOX" | tail -n 1 | sed 's/^Subject: \[proton-firesafe\] //'; }
# The body of the newest message.
last_mail() {
    awk '/^----- end of message -----$/ { last = m; m = ""; next } { m = m $0 "\n" }
        END { printf "%s", last }' "$STUB_MAILBOX"
}

expect_mail() { # DESCRIPTION SUBJECT-PATTERN
    _new=$(new_mails)
    if [ "$_new" -eq 1 ] && last_subject | grep -q -- "$2"; then
        ok "$1"
    else
        not_ok "$1 (got $_new new message(s), last: $(last_subject))"
    fi
    mark
}

expect_no_mail() {
    _new=$(new_mails)
    if [ "$_new" -eq 0 ]; then
        ok "$1"
    else
        not_ok "$1 (got $_new: $(last_subject))"
    fi
    mark
}

mail_says() { last_mail | grep -q -- "$1"; }
mail_lacks() { ! last_mail | grep -q -- "$1"; }
log_says() { grep -q -- "$1" "$PROTON_FIRESAFE_LOG"; }

# ---- the normal rotation ------------------------------------------------------

fresh "the normal rotation of two disks"

day 0
expect_mail "with no disk attached, asks for one" "no backup disk attached"
check "the request shows that no takeout has been made" mail_says "Firesafe-A: no takeout yet"

day 1
expect_no_mail "does not ask again the next day"

new_disk Firesafe-A
new_disk Firesafe-B
plug Firesafe-A
day 2
expect_mail "takes out to a newly attached disk, and says so" "Firesafe-A is in place"
check "the disk has one takeout" [ "$(takeouts_on Firesafe-A)" -eq 1 ]
check "the takeout is named by when it was made" [ "$(newest_on Firesafe-A)" = "$(stamp_of_day 2)" ]
check "no partial takeout is left behind" [ "$(partials_on Firesafe-A)" -eq 0 ]
check "the takeout has a manifest" [ -f "$V/Firesafe-A/$(stamp_of_day 2)/manifest.json" ]
check "the takeout's own log is kept beside it, on the disk" [ -f "$V/Firesafe-A/$(stamp_of_day 2).log" ]
check "takeout was asked for the default sections" \
    grep -q 'takeout run -i my-files -i devices -i photos ' "$STUB_CALLS"
check "proton-firesafe's log does not name exported files" refute log_says "secret-plans"
check "the announcement gives the date of the next swap" mail_says "due on 2 December 2026"

for n in 3 4 5 6 7 8; do day $n; done
expect_no_mail "sends nothing on the days between takeouts"
check "makes no takeout on the days between" [ "$(takeouts_on Firesafe-A)" -eq 1 ]

day 9 -1
check "takes out again a week later, an hour early by the clock" [ "$(takeouts_on Firesafe-A)" -eq 2 ]
expect_no_mail "sends nothing for a routine takeout"

day 16
check "keeps only two takeouts" [ "$(takeouts_on Firesafe-A)" -eq 2 ]
check "deletes the oldest takeout" [ ! -d "$V/Firesafe-A/$(stamp_of_day 2)" ]
check "deletes the oldest takeout's log" [ ! -f "$V/Firesafe-A/$(stamp_of_day 2).log" ]

day 23
day 29
expect_no_mail "does not ask for a swap a day early"
check "the disk is still attached on day 29" [ -d "$V/Firesafe-A" ]

day 30
expect_mail "asks for a swap four weeks after the disk was attached" "time to swap the backup disks"
check "takes out once more before the swap" [ "$(newest_on Firesafe-A)" = "$(stamp_of_day 30)" ]
check "ejects the disk" [ ! -d "$V/Firesafe-A" ]
check "the swap request names the disk to plug in" mail_says "plug in Firesafe-B"
check "the swap request gives the newest takeout" mail_says "Firesafe-A: newest takeout from 2 December 2026"

day 31
expect_no_mail "does not nag the day after the swap request"
day 36
expect_no_mail "nor six days after it"
day 37
expect_mail "reminds a week after the swap request" "no backup disk attached"

plug Firesafe-B
day 38
expect_mail "takes out to the other disk, and says so" "Firesafe-B is in place"
check "the other disk has a takeout" [ "$(takeouts_on Firesafe-B)" -eq 1 ]
check "the announcement lists both disks" mail_says "Firesafe-A: newest takeout from 2 December 2026"

for n in 45 52 59 65; do day $n; done
expect_no_mail "four quiet weeks"
day 66
expect_mail "asks for the next swap" "time to swap"
check "this time asks for Firesafe-A back" mail_says "plug in Firesafe-A"

# The wrong disk goes back in.
plug Firesafe-B
day 67
expect_mail "notices that the swapped-out disk came back" "Firesafe-B should be in the fire safe"
day 68
expect_no_mail "says so only once a week"
unplug Firesafe-B
plug Firesafe-A
day 69
expect_mail "is happy once the right disk is in" "Firesafe-A is in place"
check "which gets a fresh takeout" [ "$(newest_on Firesafe-A)" = "$(stamp_of_day 69)" ]

day 70 status >"$work/status"
check "status names the attached disk" grep -q '^Attached: *Firesafe-A, since 10 January 2027' "$work/status"
check "status says it is encrypted" grep -q '^Encrypted: *yes' "$work/status"
check "status gives the swap date" grep -q '^Swap due: *7 February 2027' "$work/status"
check "status gives the next takeout" grep -q '^Next takeout: *17 January 2027' "$work/status"
check "status lists the other disk" grep -q 'Firesafe-B: newest takeout from 7 January 2027' "$work/status"

check "every message is addressed properly" [ "$(grep -c '^To: backups@example.org$' "$STUB_MAILBOX")" -eq "$(mails)" ]
check "every message has a Date" [ "$(grep -c '^Date: ' "$STUB_MAILBOX")" -eq "$(mails)" ]
check "every message has a unique Message-ID" \
    [ "$(grep '^Message-ID: ' "$STUB_MAILBOX" | sort -u | wc -l | tr -d ' ')" -eq "$(mails)" ]

# ---- failures -------------------------------------------------------------------

fresh "takeouts that fail"
new_disk Firesafe-A
plug Firesafe-A

STUB_TAKEOUT=fail day 0
expect_mail "reports a failed takeout" "takeout to Firesafe-A failed"
check "keeps no failed takeout as a takeout" [ "$(takeouts_on Firesafe-A)" -eq 0 ]
check "keeps the takeout's output on the disk" grep -q "session expired" "$V/Firesafe-A/$(stamp_of_day 0).log"
check "the report does not name exported files" mail_lacks "secret-plans"
check "the report says where the output is" mail_says "$(stamp_of_day 0).log"

STUB_TAKEOUT=fail day 1
expect_mail "reports it again the next day" "takeout to Firesafe-A failed"
check "leaves only the newest failed attempt behind" [ "$(partials_on Firesafe-A)" -eq 1 ]

day 2
expect_mail "announces the disk once a takeout works" "Firesafe-A is in place"
check "there is one takeout" [ "$(takeouts_on Firesafe-A)" -eq 1 ]
check "and no partial one" [ "$(partials_on Firesafe-A)" -eq 0 ]
check "the logs of failed attempts are tidied up" [ ! -f "$V/Firesafe-A/$(stamp_of_day 0).log" ]

STUB_TAKEOUT=partial day 9
expect_mail "reports a takeout in which some items failed" "finished with 3 failed item(s)"
check "but keeps it" [ "$(newest_on Firesafe-A)" = "$(stamp_of_day 9)" ]
check "and counts it as the newest takeout" [ "$(cat "$V/Firesafe-A/.last-takeout")" -eq $((BASE + 9 * DAY)) ]

day 10
expect_no_mail "does not retry a takeout that only partly failed"

STUB_DF_FREE_KB=10 day 16
expect_mail "reports a disk too full for a new takeout" "Firesafe-A is too full"
check "deletes older takeouts to make room" [ "$(takeouts_on Firesafe-A)" -eq 1 ]
check "but never the newest" [ "$(newest_on Firesafe-A)" = "$(stamp_of_day 9)" ]
STUB_DF_FREE_KB=10 day 17
expect_no_mail "reports a full disk only once a week"
day 18
check "takes out when there is room again" [ "$(newest_on Firesafe-A)" = "$(stamp_of_day 18)" ]
expect_no_mail "quietly"

day 25
STUB_EJECT_FAIL=1 day 28
expect_mail "reports a disk that will not eject" "could not eject Firesafe-A"
check "which is still attached" [ -d "$V/Firesafe-A" ]
day 29
expect_mail "ejects it on the next run" "time to swap"

fresh "a takeout that takes too long"
new_disk Firesafe-A
plug Firesafe-A
day 0
mark
STUB_TAKEOUT_SECONDS=3 PROTON_FIRESAFE_WARN_SECONDS=1 day 7
expect_mail "warns about a takeout that is still running" "takeout to Firesafe-A is taking a long time"
check "which still finishes" [ "$(newest_on Firesafe-A)" = "$(stamp_of_day 7)" ]
PROTON_FIRESAFE_WARN_SECONDS=2 day 14
sleep 3
expect_no_mail "does not warn about a takeout that finished in time"

fresh "mail that cannot be sent"
STUB_MAIL_FAIL=1 day 0
check "logs mail that could not be sent" log_says "FAILED to send mail: no backup disk attached"
day 1
expect_mail "and tries again on the next run" "no backup disk attached"

# ---- disks that cannot be used ------------------------------------------------------

fresh "disks that cannot be used"
mkdir -p "$V/Firesafe-A" "$V/Elsewhere"
touch "$V/Firesafe-A/.stub-unencrypted"
check "init refuses a volume not named in DISKS" refute quietly day 0 init "$V/Elsewhere"
check "init refuses an unencrypted volume" refute quietly day 0 init "$V/Firesafe-A"
check "and does not mark it" [ ! -f "$V/Firesafe-A/.proton-firesafe" ]

day 0
expect_mail "a mounted disk that is not set up does not count" "no backup disk attached"
check "the reminder says how to set it up" mail_says "proton-firesafe init $V/Firesafe-A"

rm "$V/Firesafe-A/.stub-unencrypted"
check "init accepts an encrypted volume" quietly day 1 init "$V/Firesafe-A/"
check "and marks it" [ -f "$V/Firesafe-A/.proton-firesafe" ]

touch "$V/Firesafe-A/.stub-unencrypted"
day 2
expect_mail "refuses to take out to a disk that is not encrypted" "Firesafe-A is not encrypted"
check "and writes nothing to it" [ "$(takeouts_on Firesafe-A)" -eq 0 ]
rm "$V/Firesafe-A/.stub-unencrypted"
day 3
expect_mail "takes out once the disk is encrypted" "Firesafe-A is in place"

fresh "a locked disk"
printf '%s\n' "/dev/disk5 (synthesized):" \
    "   #:                       TYPE NAME                    SIZE       IDENTIFIER" \
    "   0:      APFS Container Scheme -                      +2.0 TB     disk5" \
    "   1:                APFS Volume $(printf '\342\201\250')Firesafe-B$(printf '\342\201\251')              1.0 TB     disk5s1" >"$work/list"
STUB_DISKUTIL_LIST="$work/list" day 0
expect_mail "asks for a disk when the attached one is locked" "no backup disk attached"
check "and says it is probably locked" mail_says "Firesafe-B is attached but not mounted"
check "and does not suggest Firesafe-A is locked" mail_lacks "Firesafe-A is attached"

# ---- locking -----------------------------------------------------------------------

fresh "overlapping runs"
new_disk Firesafe-A
plug Firesafe-A
mkdir -p "$work/state/lock"
echo $$ >"$work/state/lock/pid"
day 0 2>/dev/null
check "leaves a running takeout alone" [ "$(takeouts_on Firesafe-A)" -eq 0 ]
check "and says so in the log" log_says "is still going"
echo 999999 >"$work/state/lock/pid"
day 0
check "breaks a stale lock" [ "$(takeouts_on Firesafe-A)" -eq 1 ]
check "and removes the lock afterwards" [ ! -d "$work/state/lock" ]

# ---- commands and configuration ----------------------------------------------------

fresh "commands and configuration"
day 0 test-mail >/dev/null
expect_mail "test-mail sends a message" "test message"

new_disk Firesafe-A
plug Firesafe-A
day 0 takeout >/dev/null
check "takeout makes a takeout on demand" [ "$(takeouts_on Firesafe-A)" -eq 1 ]
day 0 eject >/dev/null
check "eject ejects the disk" [ ! -d "$V/Firesafe-A" ]
plug Firesafe-A
day 1
expect_mail "and counts as a swap" "Firesafe-A should be in the fire safe"

check "version prints the version" sh -c "'$script' version | grep -q '^proton-firesafe [0-9]'"
check "an unknown command fails with status 2" sh -c "'$script' frobnicate 2>/dev/null; [ \$? -eq 2 ]"

echo 'SWAP_AFTER_DAYS=fortnight' >>"$PROTON_FIRESAFE_CONFIG"
check "rejects a setting that is not a number" refute quietly day 2 status

fresh "no MAILTO"
echo 'MAILTO=""' >>"$PROTON_FIRESAFE_CONFIG"
day 0
expect_no_mail "sends nothing without MAILTO"
check "but logs what it would have sent" log_says "MAILTO is not set, so not sending: no backup disk attached"
check "test-mail fails without MAILTO" refute quietly day 0 test-mail

fresh "settings in the config file"
cat >>"$PROTON_FIRESAFE_CONFIG" <<'EOF'
DISKS="Vault-1 Vault-2 Vault-3"
SECTIONS="my-files revisions"
TAKEOUT_EVERY_DAYS=1
SWAP_AFTER_DAYS=3
KEEP_TAKEOUTS=1
STATUS_EVERY_DAYS=2
EOF
new_disk Vault-2
plug Vault-2
day 0
expect_mail "uses the disks named in the config file" "Vault-2 is in place"
check "and the sections" grep -q 'takeout run -i my-files -i revisions ' "$STUB_CALLS"
day 1
check "takes out as often as asked" [ "$(newest_on Vault-2)" = "$(stamp_of_day 1)" ]
check "keeps as few takeouts as asked" [ "$(takeouts_on Vault-2)" -eq 1 ]
expect_no_mail "no status report yet"
day 2
expect_mail "sends status reports when asked" "status: Vault-2 attached"
day 3
expect_mail "swaps as often as asked" "time to swap"
check "naming the other disks" mail_says "plug in Vault-1 or Vault-3"

echo "1..$tests"
[ "$failures" -eq 0 ] || echo "# $failures of $tests tests failed"
[ "$failures" -eq 0 ]
