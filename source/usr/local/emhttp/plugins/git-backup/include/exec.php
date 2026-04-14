<?PHP
/* exec.php — Execute plugin scripts for openBox dialog.
 *
 * Unraid's openBox() uses $.get() which waits for the full response.
 * We capture all output with shell_exec() and return it at once.
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

if (!in_array($script, $allowed_scripts)) {
    echo "<pre>Error: unknown script '$script'</pre>";
    exit(1);
}

// Sanitize args — only allow known safe characters
$args = preg_replace('/[^a-zA-Z0-9 _\-\.\/]/', '', $args);

$cmd = "$plugdir/scripts/$script $args 2>&1";
$output = shell_exec($cmd);

echo "<pre>";
echo htmlspecialchars($output ?: "(no output — script may have exited early)");
echo "</pre>";
?>
