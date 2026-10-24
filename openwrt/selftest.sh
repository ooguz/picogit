#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# picogit self-test for OpenWrt (and other small Linux systems).
#
# Runs clone, pull and commit against public repositories, optionally a
# push to a repository of your own, and prints a report to paste into an
# "OpenWrt test report" issue. Needs only BusyBox. Credentials are never
# shown in the output or the report.
#
#   wget -O /tmp/selftest.sh https://raw.githubusercontent.com/ooguz/picogit/main/openwrt/selftest.sh
#   sh /tmp/selftest.sh [-p https://github.com/you/scratch.git]

usage() {
	cat <<'EOF'
usage: sh selftest.sh [options]

  -b FILE   picogit binary to test (default: picogit in PATH)
  -u URL    repository for the clone and pull tests
            (default: https://github.com/ooguz/picogit.git)
  -p URL    also test commit and push to this repository: it gets one
            commit that adds a file under picogit-selftest/ and one that
            removes it again. Use a scratch repository. Credentials come
            from PICOGIT_TOKEN, ~/.netrc or the URL, as with picogit.
  -d DIR    work directory, removed at the end (default: /tmp/picogit-selftest.PID)
  -o FILE   where to write the report (default: /tmp/picogit-selftest-report.md)
  -n        skip the tests that need TLS failures from badssl.com
  -k        keep the work directory
  -h        show this help
EOF
}

PG=
URL=https://github.com/ooguz/picogit.git
PUSH_URL=
WORK=/tmp/picogit-selftest.$$
REPORT=/tmp/picogit-selftest-report.md
BADSSL=1
KEEP=

while getopts b:u:p:d:o:nkh opt; do
	case $opt in
	b) PG=$OPTARG ;;
	u) URL=$OPTARG ;;
	p) PUSH_URL=$OPTARG ;;
	d) WORK=$OPTARG ;;
	o) REPORT=$OPTARG ;;
	n) BADSSL= ;;
	k) KEEP=1 ;;
	h) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done

if [ -z "$PG" ]; then
	PG=$(command -v picogit) || { echo "picogit not found in PATH; use -b FILE" >&2; exit 2; }
fi
[ -x "$PG" ] || { echo "$PG is not executable" >&2; exit 2; }
# The process name in /proc/PID/status: at most 15 characters.
PG_NAME=$(basename "$PG" | cut -c 1-15)
if [ -e "$WORK" ]; then
	echo "$WORK already exists; choose another work directory with -d" >&2
	exit 2
fi
mkdir -p "$WORK" || exit 2
[ -n "$KEEP" ] || trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

export PICOGIT_AUTHOR_NAME="picogit selftest"
export PICOGIT_AUTHOR_EMAIL="selftest@picogit.invalid"

PASS=0
FAIL=0
RESULTS=
DETAILS=

# Remove the user:password part of URLs.
redact() {
	sed 's#://[^/@ ]*@#://***@#g'
}

# Peak memory of the last command run with run_measured, in KB.
PEAK=

# run_measured LOG CMD...: run CMD with its output in LOG and record the
# peak resident set size of picogit from /proc. VmHWM never decreases, so
# the last sample is close to the real peak; commands that finish before
# the first sample of picogit itself get none.
run_measured() {
	_log=$1
	shift
	"$@" >"$_log" 2>&1 &
	_pid=$!
	PEAK=
	while _st=$(cat "/proc/$_pid/status" 2>/dev/null); do
		case $_st in *State:[[:space:]]Z*) break ;; esac
		case $_st in "Name:"[[:space:]]"$PG_NAME"*) ;; *) sleep 0.2 2>/dev/null || sleep 1; continue ;; esac
		_hwm=$(echo "$_st" | sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\).*/\1/p')
		# Right after exec the new image is not mapped in yet.
		[ -n "$_hwm" ] && [ "$_hwm" -ge 512 ] && PEAK=$_hwm
		sleep 0.2 2>/dev/null || sleep 1
	done
	wait "$_pid"
}

# run_in DIR LOG ARGS...: run_measured picogit ARGS in DIR.
run_in() {
	_dir=$1
	_rlog=$2
	shift 2
	run_measured "$_rlog" sh -c 'cd "$0" && exec "$@"' "$_dir" "$PG" "$@"
}

# result NAME STATUS SECONDS [LOG]
result() {
	_mem=-
	[ -n "$PEAK" ] && _mem="$((PEAK / 1024)).$(((PEAK % 1024) * 10 / 1024)) MB"
	printf '%-14s %-4s %4ss  %s\n' "$1" "$2" "$3" "$_mem"
	RESULTS="$RESULTS| $1 | $2 | $3 s | $_mem |
"
	case $2 in
	PASS) PASS=$((PASS + 1)) ;;
	FAIL)
		FAIL=$((FAIL + 1))
		if [ -n "$4" ] && [ -s "$4" ]; then
			DETAILS="$DETAILS
<details><summary>$1 output</summary>

\`\`\`
$(tail -n 20 "$4" | redact)
\`\`\`
</details>
"
			tail -n 20 "$4" | redact | sed 's/^/    /'
		fi
		;;
	esac
	PEAK=
}

# Commit id that HEAD points to in the repository DIR.
head_id() {
	_head=$(cat "$1/.git/HEAD" 2>/dev/null) || return 1
	case $_head in
	"ref: "*)
		_ref=${_head#ref: }
		if [ -f "$1/.git/$_ref" ]; then
			cat "$1/.git/$_ref"
		else
			sed -n "s# $_ref\$##p" "$1/.git/packed-refs" 2>/dev/null
		fi
		;;
	*) echo "$_head" ;;
	esac
}

now() { date +%s; }

# --- environment ------------------------------------------------------

field() { sed -n "s/^$1='\{0,1\}\([^']*\)'\{0,1\}\$/\1/p" /etc/openwrt_release 2>/dev/null; }

VERSION=$("$PG" --version 2>&1)
if [ -f /etc/openwrt_release ]; then
	OS="$(field DISTRIB_DESCRIPTION)"
	TARGET="$(field DISTRIB_TARGET)"
	ARCH="$(field DISTRIB_ARCH)"
else
	OS=$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release 2>/dev/null)
	TARGET=-
	ARCH=-
fi
MODEL=$(cat /tmp/sysinfo/model 2>/dev/null)
BOARD=$(cat /tmp/sysinfo/board_name 2>/dev/null)
[ -n "$MODEL" ] || MODEL=$(tr -d '\0' 2>/dev/null </proc/device-tree/model)
KERNEL="$(uname -r) $(uname -m)"
CPU=$(sed -n 's/^\(model name\|cpu model\|Processor\)[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)
MEM=$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%d MB total, %d MB available", t / 1024, a / 1024 }' /proc/meminfo)
if grep -q 'ld-musl\|ld-linux' "$PG" 2>/dev/null; then
	LINK=dynamic
else
	LINK="static"
fi

# Join lines with ", ".
join_lines() { awk 'NR > 1 { printf ", " } { printf "%s", $0 }'; }

PKGS=
if command -v apk >/dev/null 2>&1 && [ -d /lib/apk ]; then
	PKGS=$(apk list --installed 2>/dev/null |
		sed -n 's/^\(picogit\|libmbedtls[0-9]*\|zlib\|ca-bundle\)-\([0-9][^ ]*\).*/\1 \2/p' | join_lines)
elif command -v opkg >/dev/null 2>&1; then
	PKGS=$(opkg list-installed 2>/dev/null |
		sed -n 's/^\(picogit\|libmbedtls[0-9]*\|zlib\|ca-bundle\) - \([^ ]*\).*/\1 \2/p' | join_lines)
fi
[ -n "$PKGS" ] || PKGS=-

cat <<EOF
picogit:  $VERSION ($PG, $LINK)
system:   ${OS:--} ${TARGET} ${ARCH}
device:   ${MODEL:--} ${BOARD:+($BOARD)}
kernel:   $KERNEL
memory:   $MEM
packages: $PKGS

EOF

# --- tests ------------------------------------------------------------

case $VERSION in
"picogit "*) result version PASS 0 ;;
*) echo "$VERSION" >"$WORK/version.log"; result version FAIL 0 "$WORK/version.log" ;;
esac

YEAR=$(date -u +%Y)
if [ "$YEAR" -lt 2025 ]; then
	echo "warning: the clock says $(date -u); TLS certificate checks will fail until NTP sets the time"
	result clock FAIL 0
else
	result clock PASS 0
fi

t=$(now)
if run_measured "$WORK/clone.log" "$PG" clone "$URL" "$WORK/clone" &&
	[ -f "$WORK/clone/.git/HEAD" ] && [ -n "$(head_id "$WORK/clone")" ]; then
	result clone PASS $(($(now) - t))
	CLONED=1
else
	result clone FAIL $(($(now) - t)) "$WORK/clone.log"
	CLONED=
fi

t=$(now)
if run_measured "$WORK/clone-full.log" "$PG" clone --depth 0 "$URL" "$WORK/clone-full" &&
	[ -n "$(head_id "$WORK/clone-full")" ]; then
	result clone-full PASS $(($(now) - t))
else
	result clone-full FAIL $(($(now) - t)) "$WORK/clone-full.log"
fi
rm -rf "$WORK/clone-full"

if [ -n "$CLONED" ]; then
	t=$(now)
	if run_in "$WORK/clone" "$WORK/pull.log" pull; then
		result pull PASS $(($(now) - t))
	else
		result pull FAIL $(($(now) - t)) "$WORK/pull.log"
	fi

	# A new file, a changed file, a deleted file and an ignored file.
	before=$(head_id "$WORK/clone")
	(
		cd "$WORK/clone" || exit 1
		echo "selftest" >selftest-new.txt
		echo "selftest" >>README.md
		for f in *; do
			if [ -f "$f" ] && [ "$f" != README.md ] && [ "$f" != selftest-new.txt ]; then
				rm -f "$f"
				break
			fi
		done
		echo "selftest-ignored.txt" >>.gitignore
		echo "ignored" >selftest-ignored.txt
	)
	t=$(now)
	ok=
	if run_in "$WORK/clone" "$WORK/commit.log" commit -a -m "picogit selftest"; then
		after=$(head_id "$WORK/clone")
		# Nothing is left to commit, so a second commit must fail. Removing
		# the ignored file must not change that either: it was not committed.
		if [ -n "$after" ] && [ "$after" != "$before" ] &&
			! (cd "$WORK/clone" && "$PG" commit -a -m "picogit selftest 2") >>"$WORK/commit.log" 2>&1 &&
			rm "$WORK/clone/selftest-ignored.txt" &&
			! (cd "$WORK/clone" && "$PG" commit -a -m "picogit selftest 3") >>"$WORK/commit.log" 2>&1; then
			ok=1
		fi
	fi
	if [ -n "$ok" ]; then
		result commit PASS $(($(now) - t))
	else
		result commit FAIL $(($(now) - t)) "$WORK/commit.log"
	fi
fi

if [ -n "$BADSSL" ]; then
	# picogit must refuse each of these servers.
	for bad in expired self-signed wrong.host; do
		t=$(now)
		if "$PG" -q clone "https://$bad.badssl.com/x.git" "$WORK/bad" >"$WORK/tls-$bad.log" 2>&1; then
			result "tls-$bad" FAIL $(($(now) - t)) "$WORK/tls-$bad.log"
		elif grep -q 'certificate' "$WORK/tls-$bad.log"; then
			result "tls-$bad" PASS $(($(now) - t))
		else
			# Failed for another reason (no network?), so it proves nothing.
			result "tls-$bad" FAIL $(($(now) - t)) "$WORK/tls-$bad.log"
		fi
		rm -rf "$WORK/bad"
	done
fi

if [ -n "$PUSH_URL" ]; then
	t=$(now)
	name="picogit-selftest/$(uname -m)-$(date -u +%Y%m%d%H%M%S)-$$.txt"
	ok=
	if "$PG" clone "$PUSH_URL" "$WORK/push" >"$WORK/push.log" 2>&1 &&
		mkdir -p "$WORK/push/picogit-selftest" &&
		printf 'picogit self-test\n%s\n%s %s\n' "$VERSION" "$OS" "$ARCH" >"$WORK/push/$name" &&
		(cd "$WORK/push" && "$PG" commit -a -m "picogit selftest: add $name") >>"$WORK/push.log" 2>&1 &&
		run_in "$WORK/push" "$WORK/push-run.log" push; then
		cat "$WORK/push-run.log" >>"$WORK/push.log"
		# Check from a fresh clone that the server has the commit.
		if "$PG" clone "$PUSH_URL" "$WORK/verify" >>"$WORK/push.log" 2>&1 &&
			[ -f "$WORK/verify/$name" ]; then
			ok=1
		fi
	else
		cat "$WORK/push-run.log" >>"$WORK/push.log" 2>/dev/null
	fi
	if [ -n "$ok" ]; then
		result push PASS $(($(now) - t))
	else
		result push FAIL $(($(now) - t)) "$WORK/push.log"
	fi

	# Remove the file again, which also tests deletions and a second push.
	if [ -f "$WORK/push/$name" ]; then
		t=$(now)
		rm -f "$WORK/push/$name"
		if (cd "$WORK/push" && "$PG" commit -a -m "picogit selftest: remove $name" && "$PG" push) \
			>"$WORK/push-delete.log" 2>&1; then
			result push-delete PASS $(($(now) - t))
		else
			result push-delete FAIL $(($(now) - t)) "$WORK/push-delete.log"
		fi
	fi
fi

# --- report -----------------------------------------------------------

{
	cat <<EOF
### picogit self-test

| | |
|---|---|
| picogit | $VERSION ($LINK) |
| System | ${OS:--} |
| Target / arch | ${TARGET} / ${ARCH} |
| Device | ${MODEL:--} ${BOARD:+(\`$BOARD\`)} |
| CPU | ${CPU:--} |
| Kernel | $KERNEL |
| Memory | $MEM |
| Packages | $PKGS |

| Test | Result | Time | Peak memory |
|---|---|---|---|
$RESULTS
**$PASS passed, $FAIL failed**
$DETAILS
EOF
} | redact >"$REPORT"

echo
echo "$PASS passed, $FAIL failed"
echo "Report written to $REPORT: paste it into"
echo "https://github.com/ooguz/picogit/issues/new?template=openwrt_test.yml"
[ -n "$KEEP" ] && echo "Work directory kept: $WORK"
[ "$FAIL" = 0 ]
