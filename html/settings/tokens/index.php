<?php
declare(strict_types=1);
/**
 * /settings/tokens/ — my MCP tokens for my own AI tools (screen `settings-tokens`; sso-shell.md): mint (the secret shown once, on the page
 * that minted it, with the two MCP URLs), revoke. People only (an agent never holds a person's token); the right is keys.mint_own.
 */
require_once dirname(__DIR__, 3) . '/app/bootstrap.php';
require_once dirname(__DIR__, 3) . '/app/features/settings/queries.php';
require_login();
require_human();
require_right('keys.mint_own');
$pdo = db();
$tokens = find_my_tokens($pdo, (int) current_member_id());
log_screen_view($pdo, 'settings-tokens');
if (wants_json()) {
    respond_screen(['tokens' => array_map('present_token', $tokens), 'records_url' => app_url('/mcp/records'), 'activity_url' => app_url('/mcp/activity')]);
}
$minted = $_SESSION['minted_secret'] ?? null;
unset($_SESSION['minted_secret']);
$notices = ['token_revoked' => ['success', 'Revoked the token. Anything using it has stopped working.']];
render_screen('My tokens', view('settings/tokens.php', ['tokens' => $tokens, 'minted' => $minted, 'tz' => member_timezone(),
    'notice' => sl_notice($_GET['notice'] ?? null, $notices)]), ['activeNav' => 'tokens', 'screen' => 'settings-tokens', 'entity' => 'mcp_access_token']);
