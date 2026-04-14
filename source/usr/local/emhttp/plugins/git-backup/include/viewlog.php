<?PHP
/* viewlog.php — Display the last 100 lines of the backup log.
 *
 * Note: parse_plugin_cfg() is only available inside Unraid's .page framework.
 * Standalone PHP files loaded via openBox must read config directly.
 */
$cfgFile = "/boot/config/plugins/git-backup/git-backup.cfg";
$logFile = "/var/log/git-backup.log";  // default

// Parse LOG_FILE from INI config
if (file_exists($cfgFile)) {
    $ini = parse_ini_file($cfgFile);
    if (!empty($ini['LOG_FILE'])) {
        $logFile = $ini['LOG_FILE'];
    }
}

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
