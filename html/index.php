<?php
declare(strict_types=1);
/**
 * / — Home (screen `home`). The kit's home is empty: the first slice that has something to show (the fleet, the queue) fills it.
 * JSON: present_home() — whitelisted.
 */
require_once dirname(__DIR__) . '/app/bootstrap.php';
require_once dirname(__DIR__) . '/app/features/home/queries.php';
require_once dirname(__DIR__) . '/app/features/home/present.php';
require_login();
require_right('fleet.read');
$pdo = db();
$s = home_sections($pdo, (int) current_member_id());
log_screen_view($pdo, 'home');
if (wants_json()) {
    respond_screen(present_home($s));
}
render_screen('Home', view('home/index.php', ['s' => $s]), ['activeNav' => 'home', 'screen' => 'home']);
