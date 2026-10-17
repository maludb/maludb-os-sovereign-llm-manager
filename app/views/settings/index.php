<?php
/** My settings (screen `settings`). Data: tokens (bool — may mint tokens) */
?>
<?= view('shared/page-header.php', ['id' => 'settings', 'title' => 'My settings', 'crumbs' => [['Home', '/'], ['My settings', null]], 'back' => back_link()]) ?>
<div class="main-content" id="settings-content">
    <div class="card"><div class="card-body">
        <p class="text-muted mb-3">Nothing to set yet.</p>
        <?php if ($tokens): ?>
            <?= hx_link('/settings/tokens/', '<i class="feather-key me-1"></i>My tokens', 'btn btn-light btn-touch', 'id="settings-tokens-link"') ?>
        <?php endif; ?>
    </div></div>
</div>
