<?php
/**
 * A named thing as a card (RecordCard's look — the owner's preference for named things; a node, a model, a key): the thumbnail or the
 * initial, the title as a link carrying ?back=, a line under it, badges, and a muted foot. Data: r = [id (the element's id), title, url,
 * back?, thumb? (an image URL), subtitle?, badges? [[class, words]], foot_html?, extra? (html under the title)]
 */
$url = isset($r['back']) ? with_back($r['url'], $r['back']) : $r['url'];
$initial = mb_strtoupper(mb_substr(trim((string) $r['title']) ?: '?', 0, 1));
?>
<div class="card record-card mb-2" id="<?= e($r['id']) ?>"><div class="card-body py-3 d-flex gap-3 align-items-start">
    <?php if (($r['thumb'] ?? null) !== null): ?>
        <img src="<?= e($r['thumb']) ?>" alt="" class="record-card-thumb rounded flex-shrink-0" loading="lazy" width="96" height="60">
    <?php else: ?>
        <span class="avatar-text avatar-lg rounded flex-shrink-0 record-card-initial" aria-hidden="true"><?= e($initial) ?></span>
    <?php endif; ?>
    <div class="min-w-0 flex-grow-1">
        <div class="fw-semibold text-break"><?= hx_link($url, e((string) $r['title']), 'text-dark') ?></div>
        <?php if (($r['subtitle'] ?? '') !== ''): ?><div class="fs-12 text-muted text-truncate"><?= e($r['subtitle']) ?></div><?php endif; ?>
        <?php if (!empty($r['badges'])): ?>
            <div class="d-flex flex-wrap gap-1 mt-1"><?php foreach ($r['badges'] as [$cls, $words]): ?><span class="badge <?= e($cls) ?>"><?= e($words) ?></span><?php endforeach; ?></div>
        <?php endif; ?>
        <?= $r['extra'] ?? '' ?>
        <?php if (($r['foot_html'] ?? '') !== ''): ?><div class="fs-11 text-muted mt-1"><?= $r['foot_html'] ?></div><?php endif; ?>
    </div>
</div></div>
