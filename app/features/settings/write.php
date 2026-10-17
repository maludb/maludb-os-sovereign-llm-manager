<?php
declare(strict_types=1);

/**
 * A person's own MCP tokens — the writes (actions token_mint, token_revoke; sso-shell.md). A secret is returned ONCE to the handler that
 * minted it — only its SHA-256 is stored; it never reaches a log, a notice or a later JSON answer. A token resolves only while its
 * person is admitted (mcp_resolve_token(), db/003).
 */

/** Mint a person's own MCP token (read-only, the two MCP servers): `mcp_` + 48 hex, shown once; only the hash is stored. ['id', 'secret']. */
function mint_token(PDO $pdo, int $memberId, string $label, ?int $days): array
{
    $raw = 'mcp_' . bin2hex(random_bytes(24));
    $st = $pdo->prepare("INSERT INTO mcp_access_tokens (member_id, label, token_hash, scope, expires_at)
                         VALUES (:m, :l, :h, 'mcp', CASE WHEN CAST(:d AS integer) IS NULL THEN NULL ELSE now() + make_interval(days => CAST(:d AS integer)) END) RETURNING id");
    $st->execute(['m' => $memberId, 'l' => $label, 'h' => hash('sha256', $raw), 'd' => $days]);
    return ['id' => (int) $st->fetchColumn(), 'secret' => $raw];
}

/** Revoke one of my live MCP tokens (own only). False when there is none such. */
function revoke_token(PDO $pdo, int $memberId, int $id): bool
{
    $st = $pdo->prepare("UPDATE mcp_access_tokens SET revoked_at = now() WHERE id = :id AND member_id = :m AND scope = 'mcp' AND revoked_at IS NULL RETURNING id");
    $st->execute(['id' => $id, 'm' => $memberId]);
    return $st->fetchColumn() !== false;
}
