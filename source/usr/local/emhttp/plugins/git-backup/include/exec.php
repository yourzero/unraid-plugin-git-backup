<?PHP
/* exec.php — Execute plugin scripts and stream output to openBox dialog.
 *
 * Unraid's openBox() loads a URL in an iframe. It does NOT execute commands.
 * This PHP wrapper bridges that gap: openBox loads this page, which runs
 * the script via passthru() and streams stdout/stderr to the browser.
 *
 * Usage (from JavaScript):
 *   openBox('/plugins/git-backup/include/exec.php?script=backup.sh&args=--dry-run',
 *           'Title', 800, 600, true);
 */

// Whitelist of scripts that can be executed
$allowed_scripts = [
    'backup.sh',
    'init-repo.sh',
    'ssh-keygen.sh',
];

$plugin = "git-backup";
$plugdir = "/usr/local/emhttp/plugins/$plugin";
$script = basename($_GET['script'] ?? '');
$args = $_GET['args'] ?? '';

// Validate script name against whitelist
if (!in_array($script, $allowed_scripts)) {
    echo "Error: unknown script '$script'";
    exit(1);
}

// Sanitize args — only allow known safe characters
$args = preg_replace('/[^a-zA-Z0-9 _\-\.\/]/', '', $args);

$cmd = "$plugdir/scripts/$script $args";

header('Content-Type: text/html; charset=utf-8');
echo "<pre>";
flush();

// Execute and stream output in real-time
passthru("$cmd 2>&1");

echo "</pre>";
?>
