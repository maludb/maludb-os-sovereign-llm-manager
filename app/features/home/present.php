<?php
declare(strict_types=1);

/** The JSON shape of the home page — whitelists, never a raw row. Empty in the kit. */
function present_home(array $s): array
{
    return ['sections' => []];
}
