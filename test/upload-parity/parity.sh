#!/bin/bash
# parity.sh: run inside an official php:<X.Y> image with the module source at /src and this folder at /t:
#   docker run --rm -v "$PWD/src:/src:ro" -v "$PWD/test/upload-parity:/t:ro" php:7.4-cli bash /t/parity.sh
# Builds the module from /src, then sends every case in client.php to PHP's built-in server twice: with PHP's
# own multipart parser and with the module. $_POST/$_FILES (file contents by md5) must be identical; the
# script prints DIFF for any case where they are not, and the warnings each run logged.
set -u
v=$(php -r 'echo PHP_VERSION, PHP_ZTS ? " zts" : " nts";')
B=$(mktemp -d); cp -r /src/. "$B/"; cd "$B" || exit 1
phpize >/dev/null 2>&1 && ./configure --quiet --enable-hp_uploadprogress_guard >/dev/null 2>&1
w=$(make 2>&1 | grep -E "warning:|error" | grep -v shtool); [ -n "$w" ] && echo "build warnings: $(echo "$w" | head -3)"
M="$B/modules/hp_uploadprogress_guard.so"; [ -f "$M" ] || { echo "BUILD FAILED"; exit 1; }
D=$(mktemp -d); cp /t/dump.php "$D/"
run() { local port=$1; shift; php -n -d max_file_uploads=20 -d display_errors=0 -d log_errors=1 -d error_log=/tmp/log-$port "$@" -S 127.0.0.1:$port -t "$D" >/dev/null 2>&1 & sleep 0.8; php -n /t/client.php $port > /tmp/out-$port; kill %1 2>/dev/null; wait 2>/dev/null; }
run 8101; run 8102 -d extension="$M"
echo "== PHP $v | module $(php -n -d extension="$M" -r 'echo phpversion("hp_uploadprogress_guard");') | module parser active: $(php -n -d extension="$M" --ri hp_uploadprogress_guard | sed -n 's/^multipart.form-data handler replaced => //p')"
paste -d'|' /tmp/out-8101 /tmp/out-8102 | while IFS='|' read -r a m; do n=${a%%:*}; ra=${a#*: }; rm_=${m#*: }; s="same"; [ "$ra" != "$rm_" ] && s="DIFF"; printf "  %-13s php[%s] module[%s] %s\n" "$n" "$(echo $ra | cut -c1-24)" "$(echo $rm_ | cut -c1-24)" "$s"; done
echo "  warnings logged (php / module): $(grep -c Warning /tmp/log-8101) / $(grep -c Warning /tmp/log-8102)"
grep -h "Warning" /tmp/log-810[12] | sed 's/^\[[^]]*\] //' | sort | uniq -c | sed 's/^/    /'
