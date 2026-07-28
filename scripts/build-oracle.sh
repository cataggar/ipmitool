#!/usr/bin/env bash
#
# build-oracle.sh -- build the autotools ipmitool baseline and archive it as the
# differential-test oracle for the incremental Zig rewrite (see issue #2).
#
# The oracle is the reference implementation that every Zig port stage is
# diffed against.  It must be reproducible from an arbitrary commit and it must
# record exactly how it was built.
#
# Usage:
#   scripts/build-oracle.sh [options]
#
# Options:
#   -o, --out DIR      Output directory for the oracle (default: $ORACLE_DIR)
#   -r, --ref REF      Build from this git ref in a scratch clone instead of
#                      the current working tree
#   -j, --jobs N       Parallel make jobs (default: nproc)
#       --keep-build   Do not clean the build tree when finished
#       --check        Only run the dependency check and exit
#   -h, --help         Show this help
#
# Environment variables (all optional, command line wins):
#   ORACLE_DIR                 Output directory
#                              (default: <repo>/../ipmitool-oracle)
#   ORACLE_REF                 Git ref to build (default: current working tree)
#   ORACLE_SRC_DIR             Scratch clone location used with ORACLE_REF
#                              (default: $ORACLE_DIR/src)
#   ORACLE_CONFIGURE_FLAGS     Replaces the default ./configure flags
#   ORACLE_EXTRA_CONFIGURE_FLAGS
#                              Appended after the flags above
#   ORACLE_JOBS                Parallel make jobs
#   ORACLE_KEEP_BUILD=1        Same as --keep-build
#
# The script is idempotent: re-running it rebuilds and overwrites the oracle
# directory in place.  It never stages anything in git and never deletes a
# tracked file.

set -euo pipefail

PROG="$(basename "$0")"

log()  { printf '[oracle] %s\n' "$*" >&2; }
warn() { printf '[oracle] WARNING: %s\n' "$*" >&2; }
die()  { printf '[oracle] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
	sed -n '3,37p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# --enable-intf-dummy is NOT enabled by default by configure.ac; the golden
# test harness (issue #4) drives the dummy interface, so the oracle must have
# it.  --disable-registry-download keeps the build free of network access (the
# IANA PEN registry is only fetched by `make install`).
DEFAULT_CONFIGURE_FLAGS=(
	--enable-intf-lan
	--enable-intf-lanplus
	--enable-intf-open
	--enable-intf-serial
	--enable-intf-dummy
	--enable-ipmishell
	--disable-registry-download
)

ORACLE_DIR="${ORACLE_DIR:-$(cd -- "$REPO_ROOT/.." && pwd)/ipmitool-oracle}"
ORACLE_REF="${ORACLE_REF:-}"
ORACLE_JOBS="${ORACLE_JOBS:-}"
ORACLE_KEEP_BUILD="${ORACLE_KEEP_BUILD:-0}"
CHECK_ONLY=0
SRC_DIR=""
LOG_DIR=""
LIBTOOLIZE=""

while [ $# -gt 0 ]; do
	case "$1" in
		-o|--out)     [ $# -ge 2 ] || die "$1 requires an argument"; ORACLE_DIR="$2"; shift 2 ;;
		-r|--ref)     [ $# -ge 2 ] || die "$1 requires an argument"; ORACLE_REF="$2"; shift 2 ;;
		-j|--jobs)    [ $# -ge 2 ] || die "$1 requires an argument"; ORACLE_JOBS="$2"; shift 2 ;;
		--keep-build) ORACLE_KEEP_BUILD=1; shift ;;
		--check)      CHECK_ONLY=1; shift ;;
		-h|--help)    usage; exit 0 ;;
		*)            die "unknown option: $1 (try $PROG --help)" ;;
	esac
done

if [ -n "${ORACLE_CONFIGURE_FLAGS:-}" ]; then
	# shellcheck disable=SC2206 # deliberate word splitting of a flag string
	CONFIGURE_FLAGS=( $ORACLE_CONFIGURE_FLAGS )
else
	CONFIGURE_FLAGS=( "${DEFAULT_CONFIGURE_FLAGS[@]}" )
fi
if [ -n "${ORACLE_EXTRA_CONFIGURE_FLAGS:-}" ]; then
	# shellcheck disable=SC2206 # deliberate word splitting of a flag string
	CONFIGURE_FLAGS+=( $ORACLE_EXTRA_CONFIGURE_FLAGS )
fi

if [ -z "$ORACLE_JOBS" ]; then
	ORACLE_JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi

###############################################################################
# dependency check
###############################################################################

header_present() {
	printf '#include <%s>\nint main(void){return 0;}\n' "$1" |
		gcc -E -x c - >/dev/null 2>&1
}

flags_contain() {
	local needle="$1" flag
	for flag in "${CONFIGURE_FLAGS[@]}"; do
		[ "$flag" = "$needle" ] && return 0
	done
	return 1
}

check_dependencies() {
	local missing=() tool
	for tool in git gcc make sed awk find; do
		command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
	done
	for tool in autoconf autoheader automake aclocal pkg-config; do
		command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
	done

	if command -v libtoolize >/dev/null 2>&1; then
		LIBTOOLIZE=libtoolize
	elif command -v glibtoolize >/dev/null 2>&1; then
		LIBTOOLIZE=glibtoolize
	else
		missing+=("libtool (libtoolize/glibtoolize)")
	fi

	if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
		missing+=("sha256sum or shasum")
	fi

	# Headers, not just shared libraries: configure compiles test programs.
	if command -v gcc >/dev/null 2>&1; then
		header_present openssl/evp.h ||
			missing+=("openssl development headers (openssl/evp.h)")
		if flags_contain "--enable-ipmishell" && ! header_present readline/readline.h; then
			missing+=("readline development headers (readline/readline.h)")
		fi
	fi

	if [ "${#missing[@]}" -gt 0 ]; then
		printf '[oracle] ERROR: missing build dependencies:\n' >&2
		printf '  - %s\n' "${missing[@]}" >&2
		cat >&2 <<-'EOF'

		Install them with one of:
		  Debian/Ubuntu: sudo apt-get install -y build-essential autoconf automake \
		                     libtool pkg-config libssl-dev libreadline-dev
		  Fedora/RHEL:   sudo dnf install -y gcc make autoconf automake libtool \
		                     pkgconf-pkg-config openssl-devel readline-devel
		  Azure Linux:   sudo dnf install -y build-essential autoconf automake libtool \
		                     pkg-config openssl-devel readline-devel
		EOF
		exit 1
	fi
	log "dependency check passed (libtoolize: $LIBTOOLIZE)"
}

###############################################################################
# helpers
###############################################################################

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

tool_version() {
	command -v "$1" >/dev/null 2>&1 || { echo "not installed"; return; }
	local out
	out="$("$@" 2>&1 || true)"
	printf '%s\n' "${out%%$'\n'*}"
}

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_bool() {
	if [ "$1" = yes ]; then echo true; else echo false; fi
}

# Remove a path only when git does not track it.  Never touches sources.
rm_if_untracked() {
	local path="$1"
	[ -e "$path" ] || return 0
	if git -C "$SRC_DIR" ls-files --error-unmatch "$path" >/dev/null 2>&1; then
		return 0
	fi
	rm -rf -- "$path"
}

# `make distclean` leaves the bootstrap output behind, so remove the generated
# autotools files explicitly and leave the working tree as it was found.
# Only the directories autotools generates output in are scanned, and only
# untracked files are removed, so unrelated work in the checkout is safe.
clean_build_tree() {
	log "cleaning build tree in $SRC_DIR"
	( cd "$SRC_DIR" && [ -f Makefile ] && make distclean >/dev/null 2>&1 ) || true
	(
		cd "$SRC_DIR"
		local path dir
		local build_dirs=()
		for dir in lib src include doc contrib control; do
			[ -d "$dir" ] && build_dirs+=("$dir")
		done
		if [ "${#build_dirs[@]}" -gt 0 ]; then
			while IFS= read -r path; do
				rm_if_untracked "$path"
			done < <(find "${build_dirs[@]}" \( -name 'Makefile' -o -name 'Makefile.in' \
				-o -name '.deps' -o -name '.libs' -o -name '*.o' -o -name '*.lo' \
				-o -name '*.la' -o -name '.dirstamp' \) -print)
		fi
		for path in Makefile Makefile.in aclocal.m4 autom4te.cache compile \
			config.guess config.h config.h.in 'config.h.in~' config.log \
			config.status config.sub configure depcomp install-sh libtool \
			ltmain.sh missing stamp-h1 test-driver \
			m4/libtool.m4 m4/ltoptions.m4 m4/ltsugar.m4 m4/ltversion.m4 \
			'm4/lt~obsolete.m4' src/ipmitool src/ipmievd doc/ipmitool.1 \
			doc/ipmievd.8 control/ipmitool.spec control/pkginfo control/prototype
		do
			rm_if_untracked "$path"
		done
	)
}

###############################################################################
# source tree selection
###############################################################################

prepare_source() {
	if [ -z "$ORACLE_REF" ]; then
		SRC_DIR="$REPO_ROOT"
		log "building from the current working tree: $SRC_DIR"
		return
	fi

	SRC_DIR="${ORACLE_SRC_DIR:-$ORACLE_DIR/src}"
	log "building ref '$ORACLE_REF' in scratch clone $SRC_DIR"
	mkdir -p -- "$(dirname -- "$SRC_DIR")"
	if [ ! -d "$SRC_DIR/.git" ]; then
		rm -rf -- "$SRC_DIR"
		git clone --quiet --no-hardlinks "$REPO_ROOT" "$SRC_DIR"
	fi
	git -C "$SRC_DIR" fetch --quiet --tags origin || true
	git -C "$SRC_DIR" checkout --quiet --detach "$ORACLE_REF"
	# Safe: this clone is created and owned by this script.
	git -C "$SRC_DIR" clean -xdfq
}

###############################################################################
# build
###############################################################################

run_step() {
	local name="$1" logfile="$2"
	shift 2
	log "$name"
	if ! "$@" >"$logfile" 2>&1; then
		tail -n 40 "$logfile" >&2
		die "$name failed (see $logfile)"
	fi
}

build() {
	cd "$SRC_DIR"
	run_step bootstrap "$LOG_DIR/bootstrap.log" ./bootstrap
	run_step "configure ${CONFIGURE_FLAGS[*]}" "$LOG_DIR/configure.log" \
		./configure "${CONFIGURE_FLAGS[@]}"
	run_step "make -j$ORACLE_JOBS" "$LOG_DIR/make.log" make -j"$ORACLE_JOBS"

	[ -x src/ipmitool ] || die "src/ipmitool was not produced"
	[ -x src/ipmievd ] || die "src/ipmievd was not produced"
}

###############################################################################
# archive
###############################################################################

config_h_value() {
	if grep -Eq "^#define $1 " "$SRC_DIR/config.h"; then
		echo yes
	else
		echo no
	fi
}

configure_summary() {
	sed -n '/^Interfaces (default=/,$p' "$LOG_DIR/configure.log"
}

archive() {
	log "archiving oracle into $ORACLE_DIR"
	install -m 0755 "$SRC_DIR/src/ipmitool" "$ORACLE_DIR/ipmitool"
	install -m 0755 "$SRC_DIR/src/ipmievd" "$ORACLE_DIR/ipmievd"
	install -m 0644 "$SRC_DIR/config.h" "$ORACLE_DIR/config.h"

	"$ORACLE_DIR/ipmitool" -V >"$ORACLE_DIR/ipmitool-V.txt" 2>&1 ||
		die "archived ipmitool -V failed"
	"$ORACLE_DIR/ipmitool" -h >"$ORACLE_DIR/ipmitool-h.txt" 2>&1 ||
		die "archived ipmitool -h failed"
	"$ORACLE_DIR/ipmievd" -V >"$ORACLE_DIR/ipmievd-V.txt" 2>&1 ||
		die "archived ipmievd -V failed"

	local commit describe dirty version now
	commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
	describe="$(git -C "$SRC_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
	if [ -n "$(git -C "$SRC_DIR" status --porcelain --untracked-files=no)" ]; then
		dirty=yes
	else
		dirty=no
	fi
	version="$(head -n 1 "$ORACLE_DIR/ipmitool-V.txt")"
	now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

	local gcc_v make_v autoconf_v automake_v libtool_v pkgconfig_v openssl_v
	local libcrypto_v readline_v triplet uname_s ipmitool_sha ipmievd_sha
	gcc_v="$(tool_version gcc --version)"
	make_v="$(tool_version make --version)"
	autoconf_v="$(tool_version autoconf --version)"
	automake_v="$(tool_version automake --version)"
	libtool_v="$(tool_version "$LIBTOOLIZE" --version)"
	pkgconfig_v="pkg-config $(pkg-config --version 2>/dev/null || echo unknown)"
	openssl_v="$(tool_version openssl version)"
	libcrypto_v="$(pkg-config --modversion libcrypto 2>/dev/null || echo unknown)"
	readline_v="$(pkg-config --modversion readline 2>/dev/null || echo unknown)"
	triplet="$(gcc -dumpmachine 2>/dev/null || echo unknown)"
	uname_s="$(uname -srmo 2>/dev/null || uname -a)"
	ipmitool_sha="$(sha256_of "$ORACLE_DIR/ipmitool")"
	ipmievd_sha="$(sha256_of "$ORACLE_DIR/ipmievd")"

	local intf_lan intf_lanplus intf_open intf_serial intf_usb intf_dummy
	local intf_imb intf_bmc intf_dbus intf_lipmi intf_free
	local crypto_sha256 crypto_md5 crypto_md2 readline_enabled
	intf_lan="$(config_h_value IPMI_INTF_LAN)"
	intf_lanplus="$(config_h_value IPMI_INTF_LANPLUS)"
	intf_open="$(config_h_value IPMI_INTF_OPEN)"
	intf_serial="$(config_h_value IPMI_INTF_SERIAL)"
	intf_usb="$(config_h_value IPMI_INTF_USB)"
	intf_dummy="$(config_h_value IPMI_INTF_DUMMY)"
	intf_imb="$(config_h_value IPMI_INTF_IMB)"
	intf_bmc="$(config_h_value IPMI_INTF_BMC)"
	intf_dbus="$(config_h_value IPMI_INTF_DBUS)"
	intf_lipmi="$(config_h_value IPMI_INTF_LIPMI)"
	intf_free="$(config_h_value IPMI_INTF_FREE)"
	crypto_sha256="$(config_h_value HAVE_CRYPTO_SHA256)"
	crypto_md5="$(config_h_value HAVE_CRYPTO_MD5)"
	crypto_md2="$(config_h_value HAVE_CRYPTO_MD2)"
	readline_enabled="$(config_h_value HAVE_READLINE)"

	if [ "$intf_dummy" != yes ]; then
		warn "the dummy interface is NOT enabled in this oracle, but the golden"
		warn "test harness (issue #4) drives it -- add --enable-intf-dummy"
	fi

	cat >"$ORACLE_DIR/metadata.txt" <<-EOF
		ipmitool differential-test oracle
		=================================

		generated_at      : $now
		generated_by      : scripts/build-oracle.sh
		source_repository : $REPO_ROOT
		source_commit     : $commit
		source_describe   : $describe
		source_dirty      : $dirty
		ipmitool_version  : $version

		configure_flags   : ${CONFIGURE_FLAGS[*]}

		Host
		----
		uname             : $uname_s
		host_triplet      : $triplet

		Toolchain
		---------
		gcc               : $gcc_v
		make              : $make_v
		autoconf          : $autoconf_v
		automake          : $automake_v
		libtool           : $libtool_v
		pkg-config        : $pkgconfig_v
		openssl           : $openssl_v
		libcrypto (pc)    : $libcrypto_v
		readline (pc)     : $readline_v

		Resolved feature set (from config.h)
		------------------------------------
		IPMI_INTF_LAN     : $intf_lan
		IPMI_INTF_LANPLUS : $intf_lanplus
		IPMI_INTF_OPEN    : $intf_open
		IPMI_INTF_SERIAL  : $intf_serial
		IPMI_INTF_USB     : $intf_usb
		IPMI_INTF_DUMMY   : $intf_dummy
		IPMI_INTF_IMB     : $intf_imb
		IPMI_INTF_BMC     : $intf_bmc
		IPMI_INTF_DBUS    : $intf_dbus
		IPMI_INTF_LIPMI   : $intf_lipmi
		IPMI_INTF_FREE    : $intf_free
		HAVE_CRYPTO_SHA256: $crypto_sha256
		HAVE_CRYPTO_MD5   : $crypto_md5
		HAVE_CRYPTO_MD2   : $crypto_md2
		HAVE_READLINE     : $readline_enabled

		OpenSSL algorithm probes (from configure)
		-----------------------------------------
		$(grep -E 'checking for (EVP_aes_128_cbc|EVP_sha256|MD5_Init|MD2_Init) in -lcrypto' "$LOG_DIR/configure.log" || true)

		configure summary
		-----------------
		$(configure_summary)

		Artifacts
		---------
		ipmitool sha256   : $ipmitool_sha
		ipmievd sha256    : $ipmievd_sha
	EOF

	cat >"$ORACLE_DIR/metadata.json" <<-EOF
		{
		  "generated_at": "$now",
		  "source_commit": "$commit",
		  "source_describe": "$(json_escape "$describe")",
		  "source_dirty": $(json_bool "$dirty"),
		  "ipmitool_version": "$(json_escape "$version")",
		  "configure_flags": "$(json_escape "${CONFIGURE_FLAGS[*]}")",
		  "host_triplet": "$(json_escape "$triplet")",
		  "uname": "$(json_escape "$uname_s")",
		  "toolchain": {
		    "gcc": "$(json_escape "$gcc_v")",
		    "make": "$(json_escape "$make_v")",
		    "autoconf": "$(json_escape "$autoconf_v")",
		    "automake": "$(json_escape "$automake_v")",
		    "libtool": "$(json_escape "$libtool_v")",
		    "pkg_config": "$(json_escape "$pkgconfig_v")",
		    "openssl": "$(json_escape "$openssl_v")",
		    "libcrypto": "$(json_escape "$libcrypto_v")",
		    "readline": "$(json_escape "$readline_v")"
		  },
		  "features": {
		    "intf_lan": $(json_bool "$intf_lan"),
		    "intf_lanplus": $(json_bool "$intf_lanplus"),
		    "intf_open": $(json_bool "$intf_open"),
		    "intf_serial": $(json_bool "$intf_serial"),
		    "intf_usb": $(json_bool "$intf_usb"),
		    "intf_dummy": $(json_bool "$intf_dummy"),
		    "intf_imb": $(json_bool "$intf_imb"),
		    "intf_bmc": $(json_bool "$intf_bmc"),
		    "intf_dbus": $(json_bool "$intf_dbus"),
		    "intf_lipmi": $(json_bool "$intf_lipmi"),
		    "intf_free": $(json_bool "$intf_free"),
		    "crypto_sha256": $(json_bool "$crypto_sha256"),
		    "crypto_md5": $(json_bool "$crypto_md5"),
		    "crypto_md2": $(json_bool "$crypto_md2"),
		    "readline": $(json_bool "$readline_enabled")
		  },
		  "artifacts": {
		    "ipmitool_sha256": "$ipmitool_sha",
		    "ipmievd_sha256": "$ipmievd_sha"
		  }
		}
	EOF

	(
		cd "$ORACLE_DIR"
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum ipmitool ipmievd >SHA256SUMS
		else
			shasum -a 256 ipmitool ipmievd >SHA256SUMS
		fi
	)

	log "oracle ready:"
	log "  $ORACLE_DIR/ipmitool     ($ipmitool_sha)"
	log "  $ORACLE_DIR/ipmievd      ($ipmievd_sha)"
	log "  $ORACLE_DIR/metadata.txt"
	log "  $ORACLE_DIR/metadata.json"
	log "  $ORACLE_DIR/logs/"
}

###############################################################################
# main
###############################################################################

check_dependencies
if [ "$CHECK_ONLY" -eq 1 ]; then
	exit 0
fi

mkdir -p -- "$ORACLE_DIR"
ORACLE_DIR="$(cd -- "$ORACLE_DIR" && pwd)"
LOG_DIR="$ORACLE_DIR/logs"
mkdir -p -- "$LOG_DIR"

prepare_source
build
archive

if [ "$ORACLE_KEEP_BUILD" = "1" ]; then
	log "keeping build tree (--keep-build)"
elif [ -n "$ORACLE_REF" ]; then
	log "keeping scratch clone $SRC_DIR (remove it manually when no longer needed)"
else
	clean_build_tree
fi

log "done"
