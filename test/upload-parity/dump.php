<?php
$f = array();
foreach ($_FILES as $k => $v) {
    $e = $v;
    if (isset($e['tmp_name'])) {
        if (is_array($e['tmp_name'])) { $h = array(); foreach ($e['tmp_name'] as $i => $t) { $h[$i] = $t !== '' && is_file($t) ? md5_file($t) : '-'; } $e['tmp_name'] = $h; }
        else { $e['tmp_name'] = $e['tmp_name'] !== '' && is_file($e['tmp_name']) ? md5_file($e['tmp_name']) : '-'; }
    }
    $f[$k] = $e;
}
echo http_response_code(), ' ', md5(serialize($_POST)), ' ', md5(serialize($f)), ' p=', count($_POST), ' f=', count($_FILES), "\n";
