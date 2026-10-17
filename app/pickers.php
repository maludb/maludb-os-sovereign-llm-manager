<?php
declare(strict_types=1);

/**
 * app/pickers.php — the registry of what a form can pick (app/picker.php has the contract; design-system record-picker.md).
 * One entry per record kind, added by the slice whose form chooses it:
 *   key => ['title', 'noun', 'roles' => [Sovereign LLM Manager rights, any one admits — has_right()],
 *           'params' => [an integer filter's name, or name => [the values it may take]] — the endpoint forwards nothing else,
 *           'search' => fn(PDO, string $q, array $params, int $page): array{rows, total, page, page_size, pages},   rows: [id, label, detail?, badge?, color?]
 *           'label'  => fn(PDO, int $id): ?string]
 * Every read goes through a walled view (mcp_members: an external sees only themselves; mcp_departments). A short enumeration (a level, a
 * background, a kind) stays a <select>.
 *
 * The kit registers `member` and `department`. The slices add theirs (docs/build-specs/*.md):
 *   node, model, caller key … — the slice whose form chooses it
 */

const PICKER_PAGE = 20;

/** One page of a walled list: ['rows', 'total', 'page', 'page_size', 'pages']. */
function picker_page(PDO $pdo, string $countSql, string $rowsSql, array $args, int $page): array
{
    $st = $pdo->prepare($countSql);
    $st->execute($args);
    $total = (int) $st->fetchColumn();
    $pages = max(1, (int) ceil($total / PICKER_PAGE));
    $page = max(1, min($page, $pages));
    $st = $pdo->prepare($rowsSql . ' LIMIT ' . PICKER_PAGE . ' OFFSET ' . (($page - 1) * PICKER_PAGE));
    $st->execute($args);
    return ['rows' => $st->fetchAll(), 'total' => $total, 'page' => $page, 'page_size' => PICKER_PAGE, 'pages' => $pages];
}

/** A search box's words as an ILIKE pattern (the % and _ a person types are literal). */
function picker_like(string $q): string
{
    return '%' . str_replace(['\\', '%', '_'], ['\\\\', '\\%', '\\_'], $q) . '%';
}

/** The people and agents admitted here (mcp_members — never an external to an external caller), a chip on agents and externals; $kind narrows to human or agent. */
function members_for_pick_q(PDO $pdo, string $q, array $params, int $page): array
{
    $where = '(:q = \'\' OR display_name ILIKE :like OR email ILIKE :like OR job_title ILIKE :like)';
    $args = ['q' => $q, 'like' => picker_like($q)];
    if (in_array($params['kind'] ?? null, ['human', 'agent'], true)) {
        $where .= ' AND member_kind = :kind';
        $args['kind'] = $params['kind'];
    }
    $r = picker_page($pdo, "SELECT count(*) FROM mcp_members WHERE $where",
        "SELECT member_id, display_name, job_title, email, is_agent, is_external FROM mcp_members WHERE $where ORDER BY is_agent, display_name, member_id", $args, $page);
    $r['rows'] = array_map(static fn (array $m): array => [
        'id' => (int) $m['member_id'], 'label' => (string) $m['display_name'],
        'detail' => (string) ($m['job_title'] ?: ($m['email'] ?? '')),
        'badge' => $m['is_agent'] ? 'Agent' : ($m['is_external'] ? 'External' : null), 'color' => $m['is_agent'] ? 'info' : 'warning',
    ], $r['rows']);
    return $r;
}

/** The mirror's live departments. */
function departments_for_pick(PDO $pdo, string $q, int $page): array
{
    $where = 'archived_at IS NULL AND (:q = \'\' OR name ILIKE :like OR description ILIKE :like)';
    $r = picker_page($pdo, "SELECT count(*) FROM mcp_departments WHERE $where",
        "SELECT department_id, name, description, is_system FROM mcp_departments WHERE $where ORDER BY name, department_id", ['q' => $q, 'like' => picker_like($q)], $page);
    $r['rows'] = array_map(static fn (array $d): array => [
        'id' => (int) $d['department_id'], 'label' => (string) $d['name'], 'detail' => mb_substr((string) ($d['description'] ?? ''), 0, 120),
        'badge' => $d['is_system'] ? 'Standing' : null, 'color' => 'secondary',
    ], $r['rows']);
    return $r;
}


return [
    'member' => [
        'title' => 'People and agents', 'noun' => 'person', 'roles' => ['fleet.read'], 'params' => ['kind' => ['human', 'agent']],
        'search' => static fn (PDO $pdo, string $q, array $params, int $page): array => members_for_pick_q($pdo, $q, $params, $page),
        'label' => static fn (PDO $pdo, int $id): ?string => ($v = one_value($pdo, 'SELECT display_name FROM mcp_members WHERE member_id = :id', ['id' => $id])) === null ? null : (string) $v,
    ],
    'department' => [
        'title' => 'Departments', 'noun' => 'department', 'roles' => ['fleet.read'], 'params' => [],
        'search' => static fn (PDO $pdo, string $q, array $params, int $page): array => departments_for_pick($pdo, $q, $page),
        'label' => static fn (PDO $pdo, int $id): ?string => ($v = one_value($pdo, 'SELECT name FROM mcp_departments WHERE department_id = :id AND archived_at IS NULL', ['id' => $id])) === null ? null : (string) $v,
    ],
];
