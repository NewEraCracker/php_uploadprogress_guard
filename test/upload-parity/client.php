<?php
// client.php <port> : sends each case, prints "case: <response line>"
$port = (int)$argv[1];
function part($name, $val, $file = null, $ct = 'text/plain', $extra = '') {
    $h = 'Content-Disposition: form-data; name="' . $name . '"' . ($file !== null ? '; filename="' . $file . '"' : '');
    return $h . "\r\n" . ($file !== null ? "Content-Type: $ct\r\n" : '') . $extra . "\r\n" . $val;
}
function body($b, $parts) { $s = ''; foreach ($parts as $p) { $s .= "--$b\r\n$p\r\n"; } return $s . "--$b--\r\n"; }
$bin = ''; for ($i = 0; $i < 4096; $i++) { $bin .= chr(($i * 7 + 3) & 255); }
$cases = array();
$cases['plain']      = array('AaB03x', body('AaB03x', array(part('a', '1'), part('b', 'two'), part('c[]', 'x'), part('c[]', 'y'), part('d[k][z]', 'deep'))));
$cases['files']      = array('AaB03x', body('AaB03x', array(part('t', 'v'), part('f1', 'hello', 'a.txt'), part('f2', $bin, 'bin.dat', 'application/octet-stream'), part('fa[]', 'one', '1.txt'), part('fa[]', 'two', '2.txt'))));
$cases['emptyfile']  = array('AaB03x', body('AaB03x', array(part('e', '', ''), part('n', 'z'))));
$cases['highbit']    = array('AaB03x', body('AaB03x', array(part("n\xe9\xff", "v\x80\xa0\xfe"), part("u\xc3\xa9", "\xe2\x82\xac", "\xe9t\xe9.txt"), part('w', "x\xa0y", null, 'text/plain', "X-Other: \xa0\xff\r\n"))));
$cases['folded']     = array('AaB03x', body('AaB03x', array("Content-Disposition: form-data;\r\n name=\"fold\"\r\n\r\nfoldedval", part('ok', '1'))));
$cases['quotedbnd']  = array('"q b"', body('q b', array(part('q', 'quoted'))));
$cases['bnd5116']    = array(str_repeat('b', 5116), body(str_repeat('b', 5116), array(part('k', 'long1'))));
$cases['bnd5117']    = array(str_repeat('c', 5117), body(str_repeat('c', 5117), array(part('k', 'long2'))));
$many = array(); for ($i = 0; $i < 25; $i++) { $many[] = part("m$i", "d$i", "f$i.txt"); }
$cases['toomanyfiles'] = array('AaB03x', body('AaB03x', $many));
foreach ($cases as $name => $c) {
    list($b, $data) = $c;
    $req = "POST /dump.php HTTP/1.0\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=$b\r\nContent-Length: " . strlen($data) . "\r\n\r\n" . $data;
    $s = @fsockopen('127.0.0.1', $port, $en, $es, 5);
    if (!$s) { echo "$name: no-connect\n"; continue; }
    fwrite($s, $req); $resp = stream_get_contents($s); fclose($s);
    $parts = explode("\r\n\r\n", $resp, 2);
    echo str_pad($name, 13), ': ', trim(isset($parts[1]) ? $parts[1] : '?'), "\n";
}
