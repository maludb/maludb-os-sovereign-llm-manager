<?php
declare(strict_types=1);

/**
 * What the shell reads on every render (sso-shell.md "Query functions"): the business name. Each is
 * cached for the request — one query per render. Every read goes through a view that applies the wall; nothing here re-implements a rule.
 */

/** The business's name on the header (sl_settings.business_name), else the application's. */
function business_name(PDO $pdo): string
{
    static $cache = null;
    return $cache ??= (string) (one_value($pdo, 'SELECT business_name FROM sl_settings WHERE id = 1') ?: app_name());
}

/** The path of the current request, for the sidebar's highlight. */
function current_path(): string
{
    return (string) (parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH) ?: '/');
}
