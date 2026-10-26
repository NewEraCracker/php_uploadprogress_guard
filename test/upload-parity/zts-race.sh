#!/bin/bash
# zts-race.sh: thread-safe PHP 5.6 as an Apache module (mpm_event), concurrent uploads.
#   docker build -t hp-zts56 -f test/upload-parity/Dockerfile.zts56-apache test/upload-parity
#   docker run --rm -v "$PWD/src:/src:ro" -v "$PWD/test/upload-parity:/t:ro" hp-zts56 bash /t/zts-race.sh
# Builds the module from /src and fires rounds of 8 big uploads (one 14 MB field: must be refused under
# memory_limit=16M) concurrently with 24 small ones (must pass with 3 fields + 1 file). Any big upload that
# comes back with fields=3, or any small one that does not, means requests interfere across threads.
export PATH=/opt/php/bin:$PATH
B=$(mktemp -d); cp -r /src/. "$B/"; cd "$B" && phpize >/dev/null 2>&1 && ./configure --quiet --enable-hp_uploadprogress_guard >/dev/null 2>&1 && make -s >/tmp/mk 2>&1 || { echo "BUILD FAILED"; grep -iE "error" /tmp/mk | head -3; exit 1; }
M="$B/modules/hp_uploadprogress_guard.so"
printf '<?php echo "code=", http_response_code(), " fields=", count($_POST), " files=", count($_FILES), " len=", isset($_POST["a"]) ? strlen($_POST["a"]) : 0, "\\n";' > /var/www/html/u.php
cat > /tmp/c.php <<'PHP'
<?php // c.php big|small
$kind = $argv[1];
$val = $kind === 'big' ? str_repeat('x', 14 * 1024 * 1024) : 'small';
$b = "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n$val\r\n--X\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--X\r\nContent-Disposition: form-data; name=\"c\"\r\n\r\n3\r\n--X\r\nContent-Disposition: form-data; name=\"f\"; filename=\"f.txt\"\r\nContent-Type: text/plain\r\n\r\nfiledata\r\n--X--\r\n";
$s = fsockopen('127.0.0.1', 80, $e, $es, 30);
fwrite($s, "POST /u.php HTTP/1.0\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=X\r\nContent-Length: " . strlen($b) . "\r\n\r\n" . $b);
$r = stream_get_contents($s); $p = explode("\r\n\r\n", $r, 2); echo $kind, ' ', trim(isset($p[1]) ? $p[1] : 'none'), "\n";
PHP
printf 'display_errors=Off\nmemory_limit=16M\npost_max_size=64M\nextension=%s\n' "$M" > /etc/php56/conf.d/zz.ini
apachectl -k start >/dev/null 2>&1; sleep 2
R=$(mktemp -d)
for round in 1 2 3 4 5; do
  for i in $(seq 1 8); do php -n -d memory_limit=128M /tmp/c.php big > "$R/big-$round-$i" & done
  for i in $(seq 1 24); do php -n /tmp/c.php small > "$R/small-$round-$i" & done
  wait
done
echo "== module $(php -n -d extension="$M" -r 'echo phpversion("hp_uploadprogress_guard");'), PHP $(php -n -r 'echo PHP_VERSION, PHP_ZTS ? " zts" : "";'), Apache mpm_event"
echo "  big   (must all be refused, fields=0): $(cat "$R"/big-* | sed 's/^big //' | sort | uniq -c | tr '\n' ';')"
echo "  small (must all be fields=3 files=1):  $(cat "$R"/small-* | sed 's/^small //' | sort | uniq -c | tr '\n' ';')"
apachectl -k stop >/dev/null 2>&1
