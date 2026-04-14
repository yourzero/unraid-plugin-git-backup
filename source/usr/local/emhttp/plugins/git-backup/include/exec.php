<?PHP
/* exec.php — Execute plugin scripts with real-time output.
 *
 * This is a FULL PAGE (not an openBox fragment). It streams script output
 * in real-time using output buffering tricks. Opened via window.open().
 *
 * Usage: exec.php?script=backup.sh&args=--dry-run%20--verbose
 */

$allowed_scripts = [
    'backup.sh',
    'init-repo.sh',
    'ssh-keygen.sh',
];

$plugin = "git-backup";
$plugdir = "/usr/local/emhttp/plugins/$plugin";
$script = basename($_GET['script'] ?? '');
$args = $_GET['args'] ?? '';

// Validate
if (!in_array($script, $allowed_scripts)) {
    die("<html><body><pre>Error: unknown script '$script'</pre></body></html>");
}

// Sanitize args
$args = preg_replace('/[^a-zA-Z0-9 _\-\.\/]/', '', $args);
$cmd = "$plugdir/scripts/$script $args";
?>
<html>
<head>
<title>Git Backup — <?=htmlspecialchars($script)?></title>
<style>
body {
    background: #1a1a2e;
    color: #e0e0e0;
    font-family: 'Courier New', monospace;
    font-size: 13px;
    padding: 15px;
    margin: 0;
}
pre {
    white-space: pre-wrap;
    word-wrap: break-word;
    margin: 0;
}
.header {
    color: #ff9800;
    border-bottom: 1px solid #333;
    padding-bottom: 8px;
    margin-bottom: 10px;
}
.footer {
    color: #888;
    border-top: 1px solid #333;
    padding-top: 8px;
    margin-top: 10px;
}
.error { color: #ff5252; }
.success { color: #69f0ae; }
</style>
</head>
<body>
<pre>
<span class="header">$ <?=htmlspecialchars($cmd)?></span>
<?PHP
// Flush everything so the header appears immediately
if (ob_get_level()) ob_end_flush();
ob_implicit_flush(true);
flush();

// Execute with real-time output streaming via proc_open
$descriptors = [
    0 => ['pipe', 'r'],   // stdin
    1 => ['pipe', 'w'],   // stdout
    2 => ['pipe', 'w'],   // stderr
];

$proc = proc_open($cmd, $descriptors, $pipes);

if (!is_resource($proc)) {
    echo '<span class="error">ERROR: Failed to execute command.</span>' . "\n";
    echo "Tried: $cmd\n";
    echo "Check that the script exists and is executable.\n";
} else {
    fclose($pipes[0]); // close stdin

    // Read stdout and stderr together
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $running = true;
    while ($running) {
        $stdout = fread($pipes[1], 4096);
        $stderr = fread($pipes[2], 4096);

        if ($stdout !== false && $stdout !== '') {
            echo htmlspecialchars($stdout);
            flush();
        }
        if ($stderr !== false && $stderr !== '') {
            echo '<span class="error">' . htmlspecialchars($stderr) . '</span>';
            flush();
        }

        // Check if process is still running
        $status = proc_get_status($proc);
        if (!$status['running']) {
            // Read any remaining output
            $remaining_out = stream_get_contents($pipes[1]);
            $remaining_err = stream_get_contents($pipes[2]);
            if ($remaining_out) echo htmlspecialchars($remaining_out);
            if ($remaining_err) echo '<span class="error">' . htmlspecialchars($remaining_err) . '</span>';
            $running = false;
        }

        if ($running) usleep(50000); // 50ms polling
    }

    $exit_code = $status['exitcode'];
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($proc);

    echo "\n";
    if ($exit_code === 0) {
        echo '<span class="success">✓ Completed successfully (exit code 0)</span>';
    } else {
        echo '<span class="error">✗ Exited with code ' . $exit_code . '</span>';
    }
}
?>

<span class="footer"><?=date('Y-m-d H:i:s')?></span>
</pre>
</body>
</html>
