<?php
/** Home (screen `home`): the kit's empty start page. Data: s (home_sections) */
?>
<?= view('shared/page-header.php', ['id' => 'home', 'title' => 'Home', 'crumbs' => [['Home', null]]]) ?>
<div class="main-content" id="home-content">
    <div class="card"><div class="card-body">
        <div class="empty-state"><span class="avatar-text avatar-lg rounded"><i class="feather-cpu"></i></span>
            <div class="min-w-0"><div class="fw-semibold" id="home-empty-title">Nothing here yet</div>
                <div class="fs-12 text-muted">The fleet, the queue and the runs appear here as they are built.</div></div>
        </div>
    </div></div>
</div>
