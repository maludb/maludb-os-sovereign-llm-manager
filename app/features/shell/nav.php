<?php
declare(strict_types=1);

/**
 * The shell's menu (docs/build-specs/sso-shell.md; design §9): ONE table — the sidebar and the phone's tab bar read it, so a menu item and
 * the right that opens its screen never disagree. An item shows only to a holder of its right (several joined by "|": any one).
 * The kit ships Home and Me; each slice adds its screens here and to NAV_SLICES while it is a placeholder.
 *   [nav id, url, icon, label, right, the manifest's screen id]
 */
const NAV_ITEMS = [
    'Sovereign LLM Manager' => [
        ['home', '/', 'feather-home', 'Home', 'fleet.read', 'home'],
    ],
    'Me' => [
        ['my-settings', '/settings/',        'feather-settings', 'My settings', 'fleet.read',      'settings'],
        ['tokens',      '/settings/tokens/', 'feather-key',      'My tokens',   'keys.mint_own',   'settings-tokens'],
    ],
];

/**
 * Every screen of the manifest that a later slice builds (a placeholder until then): screen id → [slice, title, the manifest's line,
 * the right that opens it (any one of "a|b"), the menu item it lives under, null]. render_nav_stub() reads it; a slice's first step
 * removes its screen's call. Empty in the kit: the first slice fills it.
 */
const NAV_SLICES = [];

/** The groups as the sidebar shows them (the first group has no caption). */
function nav_groups(): array
{
    return NAV_ITEMS;
}

/** The phone's tabs (sso-shell decision 4): Home · Me. Me opens the sidebar; without JavaScript it opens My settings. [id, url, icon, label, right, kind] */
function nav_tabs(): array
{
    return [
        ['home', '/',          'feather-home', 'Home', 'fleet.read', 'link'],
        ['me',   '/settings/', 'feather-user', 'Me',   'fleet.read', 'menu'],
    ];
}

/** The sidebar items this member may see, by group (the spec's nav_items_for). */
function nav_items_for(int $memberId): array
{
    $out = [];
    foreach (NAV_ITEMS as $group => $items) {
        $shown = array_values(array_filter($items, static fn (array $i): bool => nav_has_right($i[4])));
        if ($shown !== []) {
            $out[$group] = $shown;
        }
    }
    return $out;
}

/** A menu right may name several joined by "|": any one of them opens the item. */
function nav_has_right(string $spec): bool
{
    foreach (explode('|', $spec) as $right) {
        if (has_right($right)) {
            return true;
        }
    }
    return false;
}

/** The highest Sovereign LLM Manager role the member holds, in words — the header's badge (sl_member_roles(), db/004). */
function role_badge(): string
{
    $m = current_member();
    if ($m === null) {
        return '';
    }
    if (($m['business_role'] ?? '') === 'super_admin' && ($m['member_kind'] ?? 'human') === 'human') {
        return 'Super-admin';
    }
    $held = pg_text_array((string) (one_value(db(), 'SELECT sl_member_roles(:id)::text', ['id' => (int) $m['id']]) ?: '{}'));
    foreach (['admin' => 'LLM admin', 'user' => 'Member', 'viewer' => 'Viewer'] as $key => $label) {
        if (in_array($key, $held, true)) {
            return $label;
        }
    }
    return '';
}

/** A PostgreSQL text[] literal ({a,b}) as a PHP list; quoted elements are unquoted. */
function pg_text_array(string $literal): array
{
    $literal = trim($literal);
    if ($literal === '' || $literal === '{}') {
        return [];
    }
    $out = [];
    foreach (str_getcsv(substr($literal, 1, -1), ',', '"', '\\') as $v) {
        if ($v !== null && $v !== '') {
            $out[] = $v;
        }
    }
    return $out;
}

/** A link that navigates by HTMX into #page-content and still works as a plain link (progressive enhancement). $html is already escaped. */
function hx_link(string $url, string $html, string $class = '', string $extra = ''): string
{
    return '<a href="' . e($url) . '"' . ($class !== '' ? ' class="' . e($class) . '"' : '') . ($extra !== '' ? ' ' . $extra : '')
        . ' hx-get="' . e($url) . '" hx-target="#page-content" hx-swap="innerHTML" hx-push-url="' . e($url) . '">' . $html . '</a>';
}

/** "Back to …" from the ?back= a link carried (click-around rule): [url, label] or null. Later slices add their screens here. */
function back_link(): ?array
{
    $back = safe_local_path($_GET['back'] ?? null);
    if ($back === null) {
        return null;
    }
    $path = parse_url($back, PHP_URL_PATH) ?: '/';
    $labels = ['/' => 'Home', '/settings/' => 'My settings', '/settings/tokens/' => 'My tokens'];
    if (isset($labels[$path])) {
        return [$back, $labels[$path]];
    }
    foreach (NAV_ITEMS as $items) {
        foreach ($items as $i) {
            if (rtrim($i[1], '/') === rtrim($path, '/')) {
                return [$back, $i[3]];
            }
        }
    }
    return null;
}

/** The URL of this same page, for a ?back= (path and query as requested). */
function here_url(): string
{
    return (string) ($_SERVER['REQUEST_URI'] ?? '/');
}

function with_back(string $url, string $here): string
{
    return $url . (str_contains($url, '?') ? '&' : '?') . 'back=' . rawurlencode($here);
}

/**
 * A screen of the manifest that its slice has not built yet (Phase 2): the right checked , then the shell with one card saying which slice builds it and what it will do —
 * 200 to a person, 501 `not_built` to JSON and to a POST. bin/build_action_registry.php reads a controller that calls this as a stub, so
 * the voice surface never offers the screen. Removing the call is the slice's first step.
 */
function render_nav_stub(string $screen, int $slice): never
{
    $def = NAV_SLICES[$screen] ?? throw new InvalidArgumentException('render_nav_stub: no screen ' . $screen);
    [$owner, $title, $line, $right, $nav] = $def;
    if ($owner !== $slice) {
        throw new InvalidArgumentException("render_nav_stub: $screen is slice $owner's, not slice $slice's");
    }
    require_login();
    if (!nav_has_right($right)) {
        require_right(explode('|', $right)[0]);              // refuses in that right's sentence
    }
    $words = 'Built by slice ' . $slice . ' — ' . lcfirst(rtrim($line, '.')) . '.';
    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST') {
        emit_action_status(false, ['error' => $words]);
        if (wants_json()) {
            json_error('not_built', $words, 501);
        }
        http_response_code(501);
        echo view('shared/message.php', ['title' => 'Not built yet', 'message' => $words]);
        exit;
    }
    if (wants_json()) {
        json_error('not_built', $words, 501);
    }
    log_activity(db(), 'screen.view', null, null, ['screen' => $screen]);
    $icon = nav_icon($nav);
    render_screen($title,
        view('shared/nav-stub.php', ['screen' => $screen, 'title' => $title, 'icon' => $icon, 'slice' => $slice, 'line' => $line]),
        ['activeNav' => $nav, 'screen' => $screen]);
    exit;
}

/** A menu item's icon (the home and search have none in the sidebar). */
function nav_icon(string $nav): string
{
    foreach (NAV_ITEMS as $items) {
        foreach ($items as $i) {
            if ($i[0] === $nav) {
                return $i[2];
            }
        }
    }
    return ['home' => 'feather-home', 'search' => 'feather-search'][$nav] ?? 'feather-cpu';
}
