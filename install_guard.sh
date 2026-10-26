#!/usr/bin/env bash
# install_guard.sh: install, update or remove hp_uploadprogress_guard on Debian/Ubuntu PHP
# (the Sury / Ondrej layout: /etc/php/X.Y/mods-available, phpenmod, /usr/bin/phpX.Y).
#
#   sudo ./install_guard.sh                    every PHP version under /etc/php
#   sudo ./install_guard.sh --php 7.4 --php 8.3
#   sudo ./install_guard.sh --ref <tag|commit> install exactly the revision you audited (default: main)
#   sudo ./install_guard.sh --online           download even when run from an unpacked release bundle
#   sudo ./install_guard.sh --reload           also reload PHP-FPM and Apache (graceful, after a config test)
#   sudo ./install_guard.sh --remove [--reload]
#
# Without --reload no running service is touched: the module is active for the CLI at once and for
# PHP-FPM / Apache after their next reload, which the script prints. Re-running updates the module and
# keeps an existing ini (and so any mode / allow_ips you set). Read it before running it as root.
# Run from an unpacked release bundle (hp_uploadprogress_guard-X.Y.Z.zip / .tar.gz) it installs the files
# next to it and downloads nothing; otherwise it downloads from GitHub at --ref.
# Other layouts (cPanel EA4, DirectAdmin, RHEL, Windows): see the README.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/HOSTED-POWER/php_uploadprogress_guard"
NAME="hp_uploadprogress_guard"
REF="main"
REF_SET=0
ONLINE=0
RELOAD=0
REMOVE=0
VERSIONS=()

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--php) [ $# -ge 2 ] || usage 1; VERSIONS+=("$2"); shift 2 ;;
		--ref) [ $# -ge 2 ] || usage 1; REF="$2"; REF_SET=1; shift 2 ;;
		--online) ONLINE=1; shift ;;
		--reload) RELOAD=1; shift ;;
		--remove) REMOVE=1; shift ;;
		-h|--help) usage 0 ;;
		*) echo "unknown option: $1" >&2; usage 1 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0 ...)"
command -v phpenmod >/dev/null 2>&1 && [ -d /etc/php ] \
	|| die "no Debian/Ubuntu PHP layout here (phpenmod, /etc/php); see the README for other setups"

if [ ${#VERSIONS[@]} -eq 0 ]; then
	for d in /etc/php/*/; do
		v=$(basename "$d")
		[[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && [ -x "/usr/bin/php$v" ] && VERSIONS+=("$v")
	done
	[ ${#VERSIONS[@]} -gt 0 ] || die "no PHP found (/etc/php/X.Y with /usr/bin/phpX.Y)"
fi
for v in "${VERSIONS[@]}"; do
	case "$v" in
		5.4|5.5|5.6|7.0|7.1|7.2|7.3|7.4|8.0|8.1|8.2|8.3|8.4|8.5) ;;
		*) die "PHP $v: no prebuilt module for this version (5.4 to 8.5)" ;;
	esac
	[ -x "/usr/bin/php$v" ] && [ -d "/etc/php/$v/mods-available" ] || die "PHP $v is not installed here (/usr/bin/php$v, /etc/php/$v)"
done

# Graceful reload of what runs these PHP versions: config test first, then reload (never a hard restart),
# then a check that the running process really has (or no longer has) the module mapped.
reload_services() { # reload_services present|absent
	local want="$1" v pid
	in_state() { # in_state <pid>: the process maps the installed module (present) / no copy of it at all (absent)
		if [ "$want" = present ]; then grep -q "/$NAME.so\$" "/proc/$1/maps" 2>/dev/null
		else ! grep -q "/$NAME.so" "/proc/$1/maps" 2>/dev/null; fi
	}
	fpm_master() { # fpm_master X.Y: the live master of phpX.Y-fpm: its pid file, else a php-fpmX.Y process
		local p best=""   # titled "master process (/etc/php/X.Y/fpm/php-fpm.conf)", newest first
		p=$(cat "/run/php/php$1-fpm.pid" 2>/dev/null || true)
		if [ -n "$p" ] && [ -d "/proc/$p" ]; then echo "$p"; return; fi
		for p in $(pgrep -f "php-fpm: master process \(/etc/php/$1/fpm/php-fpm.conf\)" || true); do
			case "$(readlink "/proc/$p/exe" 2>/dev/null)" in */php-fpm$1) best="$p" ;; esac
		done
		echo "$best"
	}
	apache_parent() {
		local p
		p=$(cat /run/apache2/apache2.pid 2>/dev/null || true)
		if [ -n "$p" ] && [ -d "/proc/$p" ]; then echo "$p"; else pgrep -o -x apache2 || true; fi
	}
	wait_state() { # wait_state <lookup> [arg]: up to 10 s, looking the pid up again each time
		local i p    # (a daemonized php-fpm gets a new pid when it re-executes on USR2)
		for i in 1 2 3 4 5 6 7 8 9 10; do
			p=$("$@")
			[ -n "$p" ] && in_state "$p" && return 0
			sleep 1
		done
		return 1
	}
	for v in "${VERSIONS[@]}"; do
		command -v "php-fpm$v" >/dev/null 2>&1 || continue
		pid=$(fpm_master "$v")
		if [ -z "$pid" ]; then echo "  php$v-fpm is not running, nothing to reload"; continue; fi
		if ! "php-fpm$v" -t >/dev/null 2>&1; then echo "  NOT reloading php$v-fpm: php-fpm$v -t reports a configuration error"; FAILED=1; continue; fi
		# systemd's reload sends USR2 to the main PID; without systemd, send it directly (an init script that
		# looks for a missing pid file would report success and do nothing)
		if [ -d /run/systemd/system ]; then systemctl reload "php$v-fpm"; else kill -USR2 "$pid"; fi
		if wait_state fpm_master "$v"; then echo "  reloaded php$v-fpm (module $want)"
		else echo "  php$v-fpm reloaded but the module is not $want in its master yet: check 'systemctl status php$v-fpm'"; FAILED=1; fi
	done
	# Apache only when its mod_php is one of the versions changed here (PHP-FPM sites need no Apache reload)
	local modphp=0
	for v in "${VERSIONS[@]}"; do [ -e "/etc/apache2/mods-enabled/php$v.load" ] && modphp=1; done
	pid=$(apache_parent)
	if [ "$modphp" -eq 1 ] && [ -n "$pid" ] && command -v apache2ctl >/dev/null 2>&1; then
		if ! apache2ctl -t >/dev/null 2>&1; then echo "  NOT reloading apache2: apache2ctl -t reports a configuration error"; FAILED=1
		else
			if [ -d /run/systemd/system ]; then systemctl reload apache2; else apache2ctl -k graceful; fi
			if wait_state apache_parent; then echo "  reloaded apache2 (mod_php, module $want)"
			else echo "  apache2 reloaded but the module is not $want in it yet: check its error log"; FAILED=1; fi
		fi
	fi
}
print_reload_hint() {
	local v
	echo "Active for the CLI now. PHP-FPM and Apache pick it up on their next reload, for example:"
	for v in "${VERSIONS[@]}"; do
		command -v "php-fpm$v" >/dev/null 2>&1 && echo "  systemctl reload php$v-fpm"
	done
	for v in "${VERSIONS[@]}"; do
		[ -e "/etc/apache2/mods-enabled/php$v.load" ] && { echo "  systemctl reload apache2"; break; }
	done
	echo "(or re-run with --reload). Check on the site itself: phpinfo() shows the $NAME block."
}

if [ "$REMOVE" -eq 1 ]; then
	for v in "${VERSIONS[@]}"; do
		phpdismod -v "$v" -s ALL "$NAME" 2>/dev/null || true
		rm -f "/etc/php/$v/mods-available/$NAME.ini"
		extdir=$("/usr/bin/php$v" -n -r 'echo PHP_EXTENSION_DIR;')
		rm -f "$extdir/$NAME.so"
		echo "PHP $v: removed"
	done
	FAILED=0
	if [ "$RELOAD" -eq 1 ]; then reload_services absent; else
		echo "Running PHP-FPM / Apache processes keep the module until their next reload."; fi
	exit "$FAILED"
fi

case "$(uname -m)" in
	x86_64|amd64) SUFFIX="" ;;
	aarch64|arm64) SUFFIX="-aarch64" ;;
	*) die "no prebuilt module for $(uname -m) (x86_64 and aarch64 only); build from source, see the README" ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# An unpacked release bundle has linux/, ini/ and SHA256SUMS next to this script: use those files.
HERE=$(cd "$(dirname "$0")" && pwd)
BUNDLE=""
if [ "$ONLINE" -eq 0 ] && [ "$REF_SET" -eq 0 ] && [ -d "$HERE/linux" ] && [ -d "$HERE/ini" ] && [ -f "$HERE/SHA256SUMS" ]; then
	BUNDLE="$HERE"
fi
fetch() { # fetch <repo path> <local file>
	if [ -n "$BUNDLE" ]; then
		case "$1" in
			dist/SHA256SUMS) sed -n 's#^\([0-9a-f]\{64\}\)  linux/#\1  #p' "$BUNDLE/SHA256SUMS" > "$2"; [ -s "$2" ] ;;
			dist/*) cp "$BUNDLE/linux/${1#dist/}" "$2" ;;
			ansible/mods-available-*) cp "$BUNDLE/ini/${1#ansible/}" "$2" ;;
			*) return 1 ;;
		esac
		return
	fi
	if command -v curl >/dev/null 2>&1; then curl -fsSL "$REPO_RAW/$REF/$1" -o "$2"
	elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$REPO_RAW/$REF/$1"
	else die "need curl or wget"; fi
}
fetch dist/SHA256SUMS "$WORK/SHA256SUMS" || die "cannot download dist/SHA256SUMS at ref '$REF'"
fetch ansible/mods-available-$NAME.ini "$WORK/$NAME.ini" || die "cannot download the ini at ref '$REF'"
if [ -n "$BUNDLE" ]; then echo "Source: release bundle $BUNDLE ($(uname -m))"; else echo "Source: $REPO_RAW/$REF ($(uname -m))"; fi

FAILED=0
INSTALLED=0
for v in "${VERSIONS[@]}"; do
	php="/usr/bin/php$v"
	file="$NAME-$v$SUFFIX.so"
	if ! fetch "dist/$file" "$WORK/$file"; then echo "PHP $v: cannot download dist/$file at ref '$REF', skipped"; FAILED=1; continue; fi
	# The checksum catches a broken or partial download. SHA256SUMS comes from the same place as the
	# module, so it is not a signature: pin --ref to the revision you reviewed.
	if ! (cd "$WORK" && grep " $file\$" SHA256SUMS | sha256sum -c --quiet - >/dev/null 2>&1); then
		echo "PHP $v: checksum of $file does not match dist/SHA256SUMS, skipped (nothing changed)"; FAILED=1; continue
	fi
	extdir=$("$php" -n -r 'echo PHP_EXTENSION_DIR;')
	[ -d "$extdir" ] || { echo "PHP $v: extension dir $extdir missing, skipped"; FAILED=1; continue; }
	# New file under a temporary name in the extension dir (the work dir may be on a noexec /tmp, where no
	# library can be loaded), loaded in a separate process before anything points at it, then renamed into
	# place: running workers keep the copy they mapped.
	new="$extdir/.$NAME.so.new"
	install -m 0644 "$WORK/$file" "$new"
	if ! out=$("$php" -n -d "extension=$new" --ri "$NAME" 2>&1) || ! printf '%s\n' "$out" | grep -q '^version =>'; then
		rm -f "$new"
		echo "PHP $v: $file does not load into $php, skipped (nothing changed):"
		printf '%s\n' "$out" | grep -m2 -iE 'warning|error|unable' | sed 's/^/    /'
		FAILED=1; continue
	fi
	mv -f "$new" "$extdir/$NAME.so"
	ini="/etc/php/$v/mods-available/$NAME.ini"
	if [ -f "$ini" ]; then note="ini kept"; else install -m 0644 "$WORK/$NAME.ini" "$ini"; note="ini installed"; fi
	phpenmod -v "$v" -s ALL "$NAME"
	got=$("$php" --ri "$NAME" 2>/dev/null | sed -n 's/^version => //p')
	[ -n "$got" ] || { echo "PHP $v: installed but not loaded by the CLI, check $ini"; FAILED=1; continue; }
	echo "PHP $v: $NAME $got installed ($note: $ini)"
	INSTALLED=$((INSTALLED + 1))
done

if [ "$INSTALLED" -eq 0 ]; then echo "Nothing installed."; exit 1; fi
if [ "$RELOAD" -eq 1 ]; then reload_services present; else print_reload_hint; fi
exit "$FAILED"
