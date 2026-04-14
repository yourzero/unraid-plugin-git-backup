<?PHP
/* viewlog.php — Display the backup log. Full page, not an openBox fragment. */
$cfgFile = "/boot/config/plugins/git-backup/git-backup.cfg";
$logFile = "/var/log/git-backup.log"; // default

if (file_exists($cfgFile)) {
    $ini = parse_ini_file($cfgFile);
    if (!empty($ini['LOG_FILE'])) $logFile = $ini['LOG_FILE'];
}
?>
<html>
<head>
<title>Git Backup — Log</title>
<style>
body { background: #1a1a2e; color: #e0e0e0; font-family: 'Courier New', monospace; font-size: 13px; padding: 15px; margin: 0; }
pre { white-space: pre-wrap; word-wrap: break-word; margin: 0; }
.header { color: #ff9800; border-bottom: 1px solid #333; padding-bottom: 8px; margin-bottom: 10px; }
</style>
</head>
<body>
<pre>
<span class="header">Log: <?=htmlspecialchars($logFile)?> (last 200 lines)</span>
<?PHP
if (file_exists($logFile)) {
    $lines = file($logFile);
    $tail = array_slice($lines, -200);
    echo htmlspecialchars(implode('', $tail));
} else {
    echo "No log file found at: $logFile\n";
    echo "Run a backup first to generate the log.";
}
?>
</pre>
</body>
</html>
