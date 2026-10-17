<?php
/**
 * The app's top header (layout.php): the business name and the badge of the highest role, the switcher (K31), the theme toggle, the
 * account menu (My tokens · Sign out). Later slices add their search box and bell here.
 */
$pdo = db();
$m = current_member();
$me = (int) ($m['id'] ?? 0);
$initials = strtoupper(mb_substr((string) ($m['display_name'] ?? '?'), 0, 1));
$roleBadge = role_badge();
$badgeKind = match ($roleBadge) { 'LLM admin', 'Super-admin' => 'danger', 'Operator' => 'primary', default => 'secondary' };
?>
<!--! [Start] Header !-->
<header class="nxl-header" id="top-header">
    <div class="header-wrapper">
        <div class="header-left d-flex align-items-center gap-3">
            <a href="javascript:void(0);" class="nxl-head-mobile-toggler" id="mobile-collapse" aria-label="Menu">
                <div class="hamburger hamburger--arrowturn">
                    <div class="hamburger-box"><div class="hamburger-inner"></div></div>
                </div>
            </a>
            <div class="nxl-navigation-toggle">
                <a href="javascript:void(0);" id="menu-mini-button"><i class="feather-align-left"></i></a>
                <a href="javascript:void(0);" id="menu-expend-button" style="display: none"><i class="feather-arrow-right"></i></a>
            </div>
            <div class="header-role d-flex align-items-center" id="header-person">
                <span class="fw-semibold text-dark text-truncate" id="header-business"><?= e(business_name($pdo)) ?></span>
                <?php if ($roleBadge !== ''): ?><span class="badge bg-soft-<?= e($badgeKind) ?> text-<?= e($badgeKind) ?> ms-2 text-nowrap" id="header-role-badge"><?= e($roleBadge) ?></span><?php endif; ?>
            </div>
        </div>
        <div class="header-right ms-auto">
            <div class="d-flex align-items-center">
                <?= view('shared/app-switcher.php') ?>
                <div class="nxl-h-item dark-light-theme">
                    <a href="javascript:void(0);" class="nxl-head-link me-0 dark-button"><i class="feather-moon"></i></a>
                    <a href="javascript:void(0);" class="nxl-head-link me-0 light-button" style="display:none"><i class="feather-sun"></i></a>
                </div>
                <div class="dropdown nxl-h-item">
                    <a href="javascript:void(0);" data-bs-toggle="dropdown" role="button" data-bs-auto-close="outside" id="header-user-menu" aria-label="Your account">
                        <span class="avatar-text avatar-md user-avtar me-0"><?= e($initials) ?></span>
                    </a>
                    <div class="dropdown-menu dropdown-menu-end nxl-h-dropdown nxl-user-dropdown">
                        <div class="dropdown-header">
                            <div class="d-flex align-items-center">
                                <span class="avatar-text avatar-md user-avtar"><?= e($initials) ?></span>
                                <div class="min-w-0">
                                    <h6 class="text-dark mb-0" id="header-user-name"><?= e($m['display_name'] ?? 'Member') ?></h6>
                                    <span class="fs-12 fw-medium text-muted" id="header-user-status"><?= e($m['email'] ?? '') ?></span>
                                </div>
                            </div>
                        </div>
                        <div class="dropdown-divider"></div>
                        <?php if (has_right('keys.mint_own')): ?>
                        <a href="/settings/tokens/" class="dropdown-item" hx-get="/settings/tokens/" hx-target="#page-content" hx-push-url="/settings/tokens/" id="header-tokens-link">
                            <i class="feather-key"></i><span>My tokens</span>
                        </a>
                        <?php endif; ?>
                        <div class="dropdown-divider"></div>
                        <form method="post" action="/logout.php" class="px-2">
                            <?= csrf_field() ?>
                            <button type="submit" id="header-logout-btn" class="dropdown-item border-0 bg-transparent w-100 text-start">
                                <i class="feather-log-out"></i><span>Sign out</span>
                            </button>
                        </form>
                    </div>
                </div>
            </div>
        </div>
    </div>
</header>
<!--! [End] Header !-->
