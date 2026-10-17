<?php
declare(strict_types=1);
/** Action `token_revoke` (log `token.revoke`; confirm): one of my own MCP tokens — another member's answers 404, never "forbidden". People only. */
require_once dirname(__DIR__, 3) . '/app/bootstrap.php';
require_once dirname(__DIR__, 3) . '/app/features/settings/queries.php';
require_once dirname(__DIR__, 3) . '/app/features/settings/write.php';
sl_handler_begin();
require_human();
$pdo = db();
$me = (int) current_member_id();
$id = request_integer('token') ?? request_integer('id');
$row = $id === null ? null : find_my_token($pdo, $me, $id);
if ($row === null || $row['revoked_at'] !== null || !sl_guard($pdo, static fn (): bool => revoke_token($pdo, $me, $id))) {
    refuse(404, 'Token not found.');
}
log_activity($pdo, 'token.revoke', 'mcp_access_token', $id, ['before' => ['label' => $row['label']]]);
sl_done('Revoked the token "' . $row['label'] . '"', $id, sl_land('/settings/tokens/', 'token_revoked'), 'tokenChanged');
