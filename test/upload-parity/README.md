# Upload parser tests

Two tests for the module's multipart parser. Both build the module from `src/` inside a container; run them
from the repository root.

**`parity.sh`: same `$_POST`/`$_FILES` as PHP's own parser.** `client.php` sends a set of uploads (plain and
nested fields, binary and empty files, high-bit bytes in names, values and headers, folded headers, a quoted
boundary, boundaries of 5116 and 5117 bytes, more files than `max_file_uploads`) to PHP's built-in server,
once without and once with the module. `dump.php` prints a digest of what PHP received. Every case should read
`same`, with one intended exception: on PHP 5.4 to 8.0, `bnd5117` reads `DIFF` because the module refuses a
boundary over 5116 bytes ("Boundary too large"), as PHP 8.1 and later do themselves. The module also logs
"Maximum number of allowable file uploads" once per request where old PHP logged it once per extra file.

```sh
for v in 5.6-cli-stretch 7.4-cli 8.3-cli 8.5-cli 5.6-zts-stretch 8.4-zts-bookworm; do
  docker run --rm -v "$PWD/src:/src:ro" -v "$PWD/test/upload-parity:/t:ro" "php:$v" bash /t/parity.sh
done
```

**`zts-race.sh`: no interference between concurrent requests on a thread-safe build.** Thread-safe PHP 5.6 as
an Apache module under mpm_event; big uploads that must be refused run at the same time as small ones that
must pass. v3.2.4 let 1 of 40 refused uploads through with a truncated value (shared stop flag); v3.2.5 refuses
all of them.

```sh
docker build -t hp-zts56 -f test/upload-parity/Dockerfile.zts56-apache test/upload-parity
docker run --rm -v "$PWD/src:/src:ro" -v "$PWD/test/upload-parity:/t:ro" hp-zts56 bash /t/zts-race.sh
```

The out-of-memory behaviour is covered by `test/oom-test.sh`.
