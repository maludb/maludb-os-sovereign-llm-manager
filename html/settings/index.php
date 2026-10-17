<?php
declare(strict_types=1);
/** /settings/ — screen `settings`: my settings. The kit's page links to My tokens; a slice adds the person's preferences. */
require_once dirname(__DIR__, 2) . '/app/bootstrap.php';
require_login();
$pdo = db();
log_screen_view($pdo, 'settings');
if (wants_json()) {
    respond_screen(['tokens' => has_right('keys.mint_own')]);
}
render_screen('My settings', view('settings/index.php', ['tokens' => has_right('keys.mint_own')]), ['activeNav' => 'my-settings', 'screen' => 'settings']);
