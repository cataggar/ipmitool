#!/usr/bin/env bash
#
# sync-upstream.sh -- report the upstream drift of this fork and route every
# upstream change to the migration unit (and port issue) that owns it.
#
# Upstream is https://codeberg.org/IPMITool/ipmitool.git, default branch
# "master".  This fork's default branch is "main".  While the incremental Zig
# rewrite (issue #2) runs, upstream keeps moving; this script makes that drift
# visible and triageable.  See doc/zig-migration/upstream-sync.md.
#
# The script is strictly read-only with respect to the working tree: it only
# ever adds/refreshes the read-only "upstream" remote and fetches it.  It never
# checks out, resets, merges, rebases, stashes, cleans, stages or pushes, and
# it never writes a tracked file unless --record is given (and then only the
# state file).  It is safe to run with a dirty tree or from any branch.
#
# Usage:
#   scripts/sync-upstream.sh [options]
#
# Options:
#       --fetch            Fetch the upstream remote first (default)
#       --no-fetch         Use the refs already in the object database
#       --since REF        Diff against REF instead of the recorded sync point
#       --format FMT       Output format: text (default), json, markdown
#       --record           Write the new sync point to the state file
#       --check            Exit 1 when un-triaged upstream drift exists
#       --remote NAME      Name of the upstream remote (default: upstream)
#       --url URL          Upstream URL (default: the Codeberg repository)
#       --branch NAME      Upstream branch (default: master)
#       --upstream-ref REF Use REF as the upstream tip (default:
#                          refs/remotes/<remote>/<branch>)
#       --fork-ref REF     Fork side of the comparison (default: HEAD)
#       --state FILE       State file (default:
#                          doc/zig-migration/upstream-sync-state.json)
#       --force-url        Rewrite the remote URL if it differs
#   -h, --help             Show this help
#
# Exit status:
#   0  success (with --check: no un-triaged upstream drift)
#   1  --check found upstream commits that are not reconciled yet
#   2  usage error, network failure or any other error
#
# Environment variables (command line wins):
#   UPSTREAM_REMOTE, UPSTREAM_URL, UPSTREAM_BRANCH, UPSTREAM_SYNC_STATE

set -euo pipefail

PROG="$(basename "$0")"

log()  { printf '[sync] %s\n' "$*" >&2; }
warn() { printf '[sync] WARNING: %s\n' "$*" >&2; }
die()  { printf '[sync] ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
	sed -n '3,45p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "$SCRIPT_DIR/.. is not inside a git repository"

DEFAULT_URL="https://codeberg.org/IPMITool/ipmitool.git"

REMOTE="${UPSTREAM_REMOTE:-upstream}"
URL="${UPSTREAM_URL:-$DEFAULT_URL}"
BRANCH="${UPSTREAM_BRANCH:-master}"
STATE_FILE="${UPSTREAM_SYNC_STATE:-$REPO_ROOT/doc/zig-migration/upstream-sync-state.json}"
DOC_PATH="doc/zig-migration/upstream-sync.md"

DO_FETCH=1
SINCE_REF=""
FORMAT="text"
DO_RECORD=0
DO_CHECK=0
FORCE_URL=0
UPSTREAM_REF=""
FORK_REF="HEAD"

while [ $# -gt 0 ]; do
	case "$1" in
		--fetch)        DO_FETCH=1; shift ;;
		--no-fetch)     DO_FETCH=0; shift ;;
		--since)        [ $# -ge 2 ] || die "$1 requires an argument"; SINCE_REF="$2"; shift 2 ;;
		--format)       [ $# -ge 2 ] || die "$1 requires an argument"; FORMAT="$2"; shift 2 ;;
		--record)       DO_RECORD=1; shift ;;
		--check)        DO_CHECK=1; shift ;;
		--remote)       [ $# -ge 2 ] || die "$1 requires an argument"; REMOTE="$2"; shift 2 ;;
		--url)          [ $# -ge 2 ] || die "$1 requires an argument"; URL="$2"; shift 2 ;;
		--branch)       [ $# -ge 2 ] || die "$1 requires an argument"; BRANCH="$2"; shift 2 ;;
		--upstream-ref) [ $# -ge 2 ] || die "$1 requires an argument"; UPSTREAM_REF="$2"; shift 2 ;;
		--fork-ref)     [ $# -ge 2 ] || die "$1 requires an argument"; FORK_REF="$2"; shift 2 ;;
		--state)        [ $# -ge 2 ] || die "$1 requires an argument"; STATE_FILE="$2"; shift 2 ;;
		--force-url)    FORCE_URL=1; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              die "unknown option: $1 (try $PROG --help)" ;;
	esac
done

case "$FORMAT" in
	text|json|markdown) ;;
	md) FORMAT=markdown ;;
	*) die "unknown --format: $FORMAT (text, json, markdown)" ;;
esac

# Every git invocation goes through this: it pins the repository, works from a
# linked worktree, and keeps the read-only contract auditable in one place.
g() { git -C "$REPO_ROOT" "$@"; }

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

###############################################################################
# migration unit map -- see doc/zig-migration/upstream-sync.md
###############################################################################
#
# Every changed upstream path is classified into exactly one unit.  The order
# of the rules matters: crypto wins over transports, the build system wins over
# the directory it lives in.
#
# key|sort order|issues|description
UNIT_TABLE='
commands|10|11|lib/*.c command modules (39 files)
util|20|8|lib util layer (helper, log, strings, time)
crypto|30|9|MD5/SHA/AES/RC4 crypto helpers
transports|40|10|src/plugins/* interfaces
frontend|50|12|ipmitool/ipmievd/ipmishell front ends
headers|60|7|include/ipmitool/*.h public headers
build|70|5,13|autotools build system
ci|80|6|CI configuration
docs|90|-|manual pages and documentation
contrib|100|-|contrib/ helper scripts
control|110|-|control/ packaging
other|120|-|unclassified
'

unit_field() { # unit_field <key> <field-number>
	printf '%s\n' "$UNIT_TABLE" | awk -F'|' -v k="$1" -v f="$2" '$1==k {print $f; exit}'
}

###############################################################################
# upstream remote
###############################################################################

ensure_remote() {
	local current
	if current="$(g remote get-url "$REMOTE" 2>/dev/null)"; then
		if [ "$current" != "$URL" ]; then
			if [ "$FORCE_URL" -eq 1 ]; then
				g remote set-url "$REMOTE" "$URL"
				warn "remote '$REMOTE' URL rewritten: $current -> $URL"
			else
				die "remote '$REMOTE' points at '$current' but '$URL' was expected.
       Re-run with --force-url to rewrite it, with --url '$current' to accept
       it, or with --remote NAME to use a different remote name."
			fi
		fi
	else
		g remote add "$REMOTE" "$URL"
		log "added read-only remote '$REMOTE' -> $URL"
	fi

	# Belt and braces: make an accidental `git push upstream` fail loudly.
	local pushurl
	pushurl="$(g config --get "remote.$REMOTE.pushurl" || true)"
	if [ "$pushurl" != "DISABLED-read-only-upstream" ]; then
		g config "remote.$REMOTE.pushurl" "DISABLED-read-only-upstream"
	fi
}

fetch_upstream() {
	local out
	log "fetching $REMOTE ($URL) ..."
	if ! out="$(g fetch --no-tags --prune --quiet "$REMOTE" \
		"+refs/heads/*:refs/remotes/$REMOTE/*" 2>&1)"; then
		[ -n "$out" ] && printf '%s\n' "$out" >&2
		printf '[sync] ERROR: %s\n' "could not fetch '$REMOTE' from $URL" >&2
		cat >&2 <<-EOF
		       Check network/proxy access to the upstream host, then retry.  To
		       work from the refs already in this clone instead, re-run with:
		           $PROG --no-fetch
		EOF
		exit 2
	fi
	[ -n "$out" ] && printf '%s\n' "$out" >&2
	return 0
}

resolve() { g rev-parse --verify --quiet "$1^{commit}"; }

###############################################################################
# state file
###############################################################################

state_get() { # state_get <key>
	[ -f "$STATE_FILE" ] || return 0
	sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STATE_FILE" | head -1
}

write_state() {
	local dir tmp
	dir="$(dirname -- "$STATE_FILE")"
	[ -d "$dir" ] || die "state file directory does not exist: $dir"
	tmp="$STATE_FILE.tmp.$$"
	trap 'rm -f "$tmp"' EXIT
	cat >"$tmp" <<-EOF
	{
	  "_comment": "Last upstream commit reconciled into this fork. Updated by scripts/sync-upstream.sh --record; see doc/zig-migration/upstream-sync.md.",
	  "upstream_url": "$(json_escape "$URL")",
	  "upstream_branch": "$(json_escape "$BRANCH")",
	  "last_upstream_commit": "$UPSTREAM_SHA",
	  "last_upstream_commit_date": "$UPSTREAM_DATE",
	  "last_upstream_commit_subject": "$(json_escape "$UPSTREAM_SUBJECT")",
	  "fork_commit": "$FORK_SHA",
	  "fork_ref": "$(json_escape "$FORK_NAME")",
	  "recorded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	}
	EOF
	mv -f "$tmp" "$STATE_FILE"
	trap - EXIT
	log "recorded sync point $UPSTREAM_SHORT ($UPSTREAM_DATE) in ${STATE_FILE#"$REPO_ROOT/"}"
}

###############################################################################
# gather
###############################################################################

ensure_remote
if [ "$DO_FETCH" -eq 1 ]; then
	fetch_upstream
fi

if [ -z "$UPSTREAM_REF" ]; then
	UPSTREAM_REF="refs/remotes/$REMOTE/$BRANCH"
fi

UPSTREAM_SHA="$(resolve "$UPSTREAM_REF" || true)"
if [ -z "$UPSTREAM_SHA" ]; then
	die "cannot resolve upstream ref '$UPSTREAM_REF'.
       Run without --no-fetch to fetch it, or pass --upstream-ref."
fi

FORK_SHA="$(resolve "$FORK_REF" || true)"
[ -n "$FORK_SHA" ] || die "cannot resolve fork ref '$FORK_REF'"
FORK_NAME="$(g rev-parse --abbrev-ref "$FORK_REF" 2>/dev/null || echo "$FORK_REF")"
[ "$FORK_NAME" = "HEAD" ] && FORK_NAME="$(g symbolic-ref --short -q HEAD || echo detached)"

MERGE_BASE="$(g merge-base "$FORK_SHA" "$UPSTREAM_SHA" 2>/dev/null || true)"
[ -n "$MERGE_BASE" ] || die "no merge base between '$FORK_REF' and '$UPSTREAM_REF' -- \
unrelated histories?"

STATE_SHA="$(state_get last_upstream_commit)"
SINCE_SOURCE=""
SINCE=""
if [ -n "$SINCE_REF" ]; then
	SINCE="$(resolve "$SINCE_REF" || true)"
	[ -n "$SINCE" ] || die "cannot resolve --since ref '$SINCE_REF'"
	SINCE_SOURCE="--since $SINCE_REF"
elif [ -n "$STATE_SHA" ]; then
	if SINCE="$(resolve "$STATE_SHA" || true)" && [ -n "$SINCE" ]; then
		SINCE_SOURCE="state file ${STATE_FILE#"$REPO_ROOT/"}"
	else
		warn "recorded sync point $STATE_SHA is not in this clone (fetch it or fix \
${STATE_FILE#"$REPO_ROOT/"}); falling back to the merge base"
		SINCE="$MERGE_BASE"
		SINCE_SOURCE="merge base (recorded sync point unavailable)"
	fi
else
	SINCE="$MERGE_BASE"
	SINCE_SOURCE="merge base (no sync point recorded yet)"
fi

if ! g merge-base --is-ancestor "$SINCE" "$UPSTREAM_SHA" 2>/dev/null; then
	warn "sync point $(g rev-parse --short "$SINCE") is not an ancestor of \
$UPSTREAM_REF -- upstream history may have been rewritten; the delta below is \
a plain diff between the two commits"
fi

read -r UPSTREAM_SHORT UPSTREAM_DATE <<<"$(g log -1 --format='%h %cs' "$UPSTREAM_SHA")"
UPSTREAM_SUBJECT="$(g log -1 --format='%s' "$UPSTREAM_SHA")"
SINCE_SHORT="$(g rev-parse --short "$SINCE")"
SINCE_DATE="$(g log -1 --format='%cs' "$SINCE")"
FORK_SHORT="$(g rev-parse --short "$FORK_SHA")"
MERGE_BASE_SHORT="$(g rev-parse --short "$MERGE_BASE")"

COMMITS_BEHIND="$(g rev-list --count "$SINCE..$UPSTREAM_SHA")"
COMMITS_AHEAD="$(g rev-list --count "$UPSTREAM_SHA..$FORK_SHA")"

# tab separated: sha<TAB>date<TAB>author<TAB>subject, newest first
COMMIT_LIST="$(g log --format='%h	%cs	%an	%s' "$SINCE..$UPSTREAM_SHA")"

# Per-file records, one per line, tab separated:
#   order  unit  issues  path  added  deleted  status  commits
FILE_RECORDS="$(
	{
		printf '#S numstat\n'
		g diff --numstat --no-renames "$SINCE" "$UPSTREAM_SHA"
		printf '#S status\n'
		g diff --name-status --no-renames "$SINCE" "$UPSTREAM_SHA"
		printf '#S log\n'
		g log --format='#C %h' --name-only --no-renames "$SINCE..$UPSTREAM_SHA"
	} | awk -v units="$UNIT_TABLE" '
	BEGIN {
		FS = "\t"
		n = split(units, rows, "\n")
		for (i = 1; i <= n; i++) {
			if (rows[i] == "") continue
			split(rows[i], f, "|")
			order[f[1]] = f[2]
			issue[f[1]] = f[3]
		}
	}
	function unit_for(p) {
		if (p ~ /^src\/plugins\/lan\/md5\.[ch]$/) return "crypto"
		if (p ~ /^src\/plugins\/lanplus\/lanplus_crypt/) return "crypto"
		if (p == "configure.ac" || p == "bootstrap" || p == "Makefile.am") return "build"
		if (p ~ /\/Makefile\.am$/ || p ~ /\.m4$/) return "build"
		if (p ~ /^lib\/ipmi_main\.c$/) return "frontend"
		if (p ~ /^lib\/(helper|log|ipmi_strings|ipmi_time)\.c$/) return "util"
		if (p ~ /^lib\//) return "commands"
		if (p ~ /^src\/plugins\//) return "transports"
		if (p ~ /^src\//) return "frontend"
		if (p ~ /^include\//) return "headers"
		if (p ~ /^\.github\// || p == ".woodpecker.yml" || p ~ /^\.woodpecker\//) return "ci"
		if (p ~ /^buildenv\// || p ~ /^\.travis\.yml$/) return "ci"
		if (p ~ /^doc\//) return "docs"
		if (p ~ /^contrib\//) return "contrib"
		if (p ~ /^control\//) return "control"
		return "other"
	}
	/^#S / { section = $0; sub(/^#S /, "", section); next }
	section == "numstat" {
		if (NF < 3) next
		add[$3] = $1; del[$3] = $2; seen[$3] = 1; next
	}
	section == "status" {
		if (NF < 2) next
		st[$2] = $1; seen[$2] = 1; next
	}
	section == "log" {
		if ($0 ~ /^#C /) { sha = substr($0, 4); next }
		if ($0 == "") next
		if (index(" " commits[$0] " ", " " sha " ") == 0)
			commits[$0] = (commits[$0] == "" ? sha : commits[$0] " " sha)
		next
	}
	END {
		for (p in seen) {
			u = unit_for(p)
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
				order[u], u, issue[u], p, \
				(add[p] == "" ? "0" : add[p]), \
				(del[p] == "" ? "0" : del[p]), \
				(st[p] == "" ? "?" : st[p]), \
				commits[p]
		}
	}' | LC_ALL=C sort -t'	' -k1,1n -k4,4
)"

FILES_CHANGED=0
TOTAL_ADD=0
TOTAL_DEL=0
if [ -n "$FILE_RECORDS" ]; then
	FILES_CHANGED="$(printf '%s\n' "$FILE_RECORDS" | wc -l | tr -d ' ')"
	read -r TOTAL_ADD TOTAL_DEL <<<"$(printf '%s\n' "$FILE_RECORDS" |
		awk -F'\t' '{ if ($5 != "-") a += $5; if ($6 != "-") d += $6 } END { printf "%d %d\n", a, d }')"
fi

units_in_report() {
	[ -n "$FILE_RECORDS" ] || return 0
	printf '%s\n' "$FILE_RECORDS" | awk -F'\t' '!s[$2]++ { print $2 }'
}

###############################################################################
# render
###############################################################################

issue_label() { # "-" -> "n/a", "5,13" -> "#5, #13"
	case "$1" in
		-|"") printf 'n/a' ;;
		*) printf '%s' "$1" | sed -e 's/,/, #/g' -e 's/^/#/' ;;
	esac
}

render_text() {
	printf '===============================================================================\n'
	printf ' upstream sync report\n'
	printf '===============================================================================\n'
	printf ' upstream remote    : %s (%s)\n' "$REMOTE" "$URL"
	printf ' upstream ref       : %s\n' "$UPSTREAM_REF"
	printf ' upstream head      : %s  %s  %s\n' "$UPSTREAM_SHORT" "$UPSTREAM_DATE" "$UPSTREAM_SUBJECT"
	printf ' sync point         : %s  %s  (%s)\n' "$SINCE_SHORT" "$SINCE_DATE" "$SINCE_SOURCE"
	printf ' fork ref           : %s (%s)\n' "$FORK_NAME" "$FORK_SHORT"
	printf ' merge base         : %s\n' "$MERGE_BASE_SHORT"
	printf ' upstream commits   : %s new since the sync point\n' "$COMMITS_BEHIND"
	printf ' fork-only commits  : %s not in upstream\n' "$COMMITS_AHEAD"
	printf ' files changed      : %s (+%s/-%s)\n' "$FILES_CHANGED" "$TOTAL_ADD" "$TOTAL_DEL"
	printf '\n'

	if [ "$COMMITS_BEHIND" -eq 0 ]; then
		printf ' No upstream changes since %s -- the fork is up to date.\n' "$SINCE_SHORT"
		return 0
	fi

	printf ' new upstream commits (newest first)\n'
	printf '%s\n' "$COMMIT_LIST" |
		awk -F'\t' '{ printf "   %-9s %s  %-22.22s %s\n", $1, $2, $3, $4 }'
	printf '\n'

	printf ' changed files by migration unit\n'
	local unit desc issues
	while IFS= read -r unit; do
		[ -n "$unit" ] || continue
		desc="$(unit_field "$unit" 4)"
		issues="$(issue_label "$(unit_field "$unit" 3)")"
		printf '\n   %s -- %s [%s]\n' "$unit" "$desc" "$issues"
		printf '%s\n' "$FILE_RECORDS" |
			awk -F'\t' -v u="$unit" '$2 == u {
				printf "     %s  %-46s +%-6s -%-6s %s\n", $7, $4, $5, $6, $8
			}'
	done <<<"$(units_in_report)"

	printf '\n triage each file with %s\n' "$DOC_PATH"
}

# shellcheck disable=SC2016 # backticks in the format strings are markdown, not command substitution
render_markdown() {
	printf '# Upstream sync report\n\n'
	printf '| field | value |\n| --- | --- |\n'
	printf '| upstream remote | `%s` (%s) |\n' "$REMOTE" "$URL"
	printf '| upstream ref | `%s` |\n' "$UPSTREAM_REF"
	printf '| upstream head | `%s` %s — %s |\n' "$UPSTREAM_SHORT" "$UPSTREAM_DATE" "$UPSTREAM_SUBJECT"
	printf '| sync point | `%s` %s (%s) |\n' "$SINCE_SHORT" "$SINCE_DATE" "$SINCE_SOURCE"
	printf '| fork ref | `%s` (`%s`) |\n' "$FORK_NAME" "$FORK_SHORT"
	printf '| merge base | `%s` |\n' "$MERGE_BASE_SHORT"
	printf '| upstream commits behind | %s |\n' "$COMMITS_BEHIND"
	printf '| fork-only commits | %s |\n' "$COMMITS_AHEAD"
	printf '| files changed | %s (+%s/-%s) |\n' "$FILES_CHANGED" "$TOTAL_ADD" "$TOTAL_DEL"
	printf '\n'

	if [ "$COMMITS_BEHIND" -eq 0 ]; then
		printf 'No upstream changes since `%s` — the fork is up to date.\n' "$SINCE_SHORT"
		return 0
	fi

	printf '## New upstream commits\n\n'
	printf '| commit | date | author | subject |\n| --- | --- | --- | --- |\n'
	printf '%s\n' "$COMMIT_LIST" |
		awk -F'\t' '{ gsub(/\|/, "\\|", $4); printf "| `%s` | %s | %s | %s |\n", $1, $2, $3, $4 }'
	printf '\n## Changed files by migration unit\n\n'
	printf '| file | unit | issue | +/- | change | commits |\n'
	printf '| --- | --- | --- | --- | --- | --- |\n'
	printf '%s\n' "$FILE_RECORDS" | awk -F'\t' '
		function issues(s,   n, a, i, out) {
			if (s == "-" || s == "") return "n/a"
			n = split(s, a, ",")
			for (i = 1; i <= n; i++) out = out (i == 1 ? "" : ", ") "#" a[i]
			return out
		}
		NF >= 8 {
			printf "| `%s` | %s | %s | +%s/-%s | %s | %s |\n", \
				$4, $2, issues($3), $5, $6, $7, $8
		}'
	printf '\nTriage every row with `%s`.\n' "$DOC_PATH"
}

render_json() {
	printf '{\n'
	printf '  "upstream_remote": "%s",\n' "$(json_escape "$REMOTE")"
	printf '  "upstream_url": "%s",\n' "$(json_escape "$URL")"
	printf '  "upstream_ref": "%s",\n' "$(json_escape "$UPSTREAM_REF")"
	printf '  "upstream_head": { "sha": "%s", "short": "%s", "date": "%s", "subject": "%s" },\n' \
		"$UPSTREAM_SHA" "$UPSTREAM_SHORT" "$UPSTREAM_DATE" "$(json_escape "$UPSTREAM_SUBJECT")"
	printf '  "sync_point": { "sha": "%s", "short": "%s", "date": "%s", "source": "%s" },\n' \
		"$SINCE" "$SINCE_SHORT" "$SINCE_DATE" "$(json_escape "$SINCE_SOURCE")"
	printf '  "fork": { "ref": "%s", "sha": "%s", "short": "%s" },\n' \
		"$(json_escape "$FORK_NAME")" "$FORK_SHA" "$FORK_SHORT"
	printf '  "merge_base": "%s",\n' "$MERGE_BASE"
	printf '  "commits_behind": %s,\n' "$COMMITS_BEHIND"
	printf '  "commits_ahead": %s,\n' "$COMMITS_AHEAD"
	printf '  "files_changed": %s,\n' "$FILES_CHANGED"
	printf '  "insertions": %s,\n' "$TOTAL_ADD"
	printf '  "deletions": %s,\n' "$TOTAL_DEL"

	printf '  "commits": [\n'
	if [ -n "$COMMIT_LIST" ]; then
		printf '%s\n' "$COMMIT_LIST" | awk -F'\t' '
			function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
			{
				printf "%s    { \"sha\": \"%s\", \"date\": \"%s\", \"author\": \"%s\", \"subject\": \"%s\" }", \
					(NR == 1 ? "" : ",\n"), $1, $2, esc($3), esc($4)
			}
			END { if (NR) printf "\n" }'
	fi
	printf '  ],\n'

	printf '  "files": [\n'
	if [ -n "$FILE_RECORDS" ]; then
		printf '%s\n' "$FILE_RECORDS" | awk -F'\t' '
			function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
			{
				nc = split($8, cs, " ")
				clist = ""
				for (i = 1; i <= nc; i++)
					if (cs[i] != "") clist = clist (clist == "" ? "" : ", ") "\"" cs[i] "\""
				issues = ""
				if ($3 != "-" && $3 != "") {
					ni = split($3, is, ",")
					for (i = 1; i <= ni; i++)
						issues = issues (issues == "" ? "" : ", ") is[i]
				}
				printf "%s    { \"path\": \"%s\", \"unit\": \"%s\", \"issues\": [%s], \"status\": \"%s\", \"insertions\": %s, \"deletions\": %s, \"commits\": [%s] }", \
					(NR == 1 ? "" : ",\n"), esc($4), $2, issues, $7, \
					($5 == "-" ? 0 : $5), ($6 == "-" ? 0 : $6), clist
			}
			END { if (NR) printf "\n" }'
	fi
	printf '  ]\n'
	printf '}\n'
}

case "$FORMAT" in
	text)     render_text ;;
	markdown) render_markdown ;;
	json)     render_json ;;
esac

if [ "$DO_RECORD" -eq 1 ]; then
	if [ "$DO_FETCH" -eq 0 ]; then
		warn "--record with --no-fetch: recording possibly stale ref $UPSTREAM_REF"
	fi
	write_state
fi

if [ "$DO_CHECK" -eq 1 ] && [ "$COMMITS_BEHIND" -gt 0 ]; then
	printf '[sync] %s upstream commit(s) are not reconciled yet (sync point %s)\n' \
		"$COMMITS_BEHIND" "$SINCE_SHORT" >&2
	exit 1
fi

exit 0
