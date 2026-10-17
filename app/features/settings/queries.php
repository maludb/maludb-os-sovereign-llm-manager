<?php
declare(strict_types=1);

/**
 * A person's own MCP tokens — the reads (screen `settings-tokens`, sso-shell.md): scope mcp only (a person's API key is the keys screen's, not this one).
 * A token's hash is never read here. The writes are in write.php.
 */

/** My MCP tokens, newest first: id, label, last used, expiry, revoked — never the hash. */
function find_my_tokens(PDO $pdo, int $memberId): array
{
    $st = $pdo->prepare("SELECT id, label, last_used_at, expires_at, revoked_at, created_at FROM mcp_access_tokens
                          WHERE member_id = :m AND scope = 'mcp' ORDER BY created_at DESC, id DESC");
    $st->execute(['m' => $memberId]);
    return $st->fetchAll();
}

/** One of my MCP tokens, or null — another member's never answers. */
function find_my_token(PDO $pdo, int $memberId, int $id): ?array
{
    $st = $pdo->prepare("SELECT id, label, last_used_at, expires_at, revoked_at, created_at FROM mcp_access_tokens WHERE id = :id AND member_id = :m AND scope = 'mcp'");
    $st->execute(['id' => $id, 'm' => $memberId]);
    $r = $st->fetch();
    return $r === false ? null : $r;
}

/** Is a token live (neither revoked nor expired)? */
function token_live(array $t): bool
{
    return ($t['revoked_at'] ?? null) === null && (($t['expires_at'] ?? null) === null || strtotime((string) $t['expires_at']) > time());
}

/** A token's JSON — a whitelist: never its value or hash. */
function present_token(array $t): array
{
    return ['token_id' => (int) $t['id'], 'label' => $t['label'], 'created_at' => json_ts($t['created_at']), 'last_used_at' => json_ts($t['last_used_at'] ?? null),
            'expires_at' => json_ts($t['expires_at'] ?? null), 'revoked' => ($t['revoked_at'] ?? null) !== null, 'live' => token_live($t)];
}
