<?PHP
/* viewlog.php — Display the last 100 lines of the backup log */
$cfg = parse_plugin_cfg("git-backup");
$logFile = $cfg['LOG_FILE'] ?? '/var/log/git-backup.log';

header('Content-Type: text/html; charset=utf-8');
echo "<pre>";
if (file_exists($logFile)) {
    passthru("tail -100 " . escapeshellarg($logFile));
} else {
    echo "No log file found at: $logFile\n";
    echo "Run a backup first to generate the log.";
}
echo "</pre>";
?>
