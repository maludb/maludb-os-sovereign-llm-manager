<?php
/**
 * A placeholder screen (render_nav_stub, Phase 2): the page header and one card saying which slice builds it and what it will do (the
 * manifest's line). 
 * Data: screen, title, icon, slice, line
 */
$id = $screen;
$crumbs = $screen === 'home' ? [['Home', null]] : [['Home', '/'], [$title, null]];
?>
<?= view('shared/page-header.php', ['id' => $id, 'title' => $title, 'crumbs' => $crumbs, 'back' => back_link()]) ?>
<div class="main-content" id="<?= e($id) ?>-content">
    <div class="card coming-card" id="nav-stub"><div class="card-body">
        <div class="empty-state"><span class="avatar-text avatar-lg rounded"><i class="<?= e($icon) ?>"></i></span>
            <div class="min-w-0"><div class="fw-semibold" id="nav-stub-title"><?= e($title) ?> is not built yet</div>
                <div class="fs-12 text-muted" id="nav-stub-line">Built by slice <?= (int) $slice ?> — <?= e(lcfirst(rtrim($line, '.'))) ?>.</div>
            </div></div>
    </div></div>
</div>
