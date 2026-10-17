<?php
declare(strict_types=1);
/** Draws Sovereign LLM Manager's brand images with GD (the logo, the abbreviated mark, the favicon, the PWA icons): php bin/make_brand_images.php. Rerun after changing the mark. */
$dir = dirname(__DIR__) . '/html/assets/images';
$font = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf';
$indigo = [55, 88, 230];
function mark(int $size, bool $rounded = true): GdImage
{
    global $indigo;
    $im = imagecreatetruecolor($size, $size);
    imagesavealpha($im, true);
    imagealphablending($im, false);
    imagefill($im, 0, 0, imagecolorallocatealpha($im, 0, 0, 0, 127));
    imagealphablending($im, true);
    $bg = imagecolorallocate($im, ...$indigo);
    $r = $rounded ? (int) round($size * 0.22) : 0;
    imagefilledrectangle($im, $r, 0, $size - 1 - $r, $size - 1, $bg);
    imagefilledrectangle($im, 0, $r, $size - 1, $size - 1 - $r, $bg);
    foreach ([[$r, $r], [$size - 1 - $r, $r], [$r, $size - 1 - $r], [$size - 1 - $r, $size - 1 - $r]] as [$cx, $cy]) {
        imagefilledellipse($im, $cx, $cy, $r * 2, $r * 2, $bg);
    }
    // a chip: a white die with a yellow core and pins on every side -- a model node
    $yellow = imagecolorallocate($im, 255, 214, 64);
    $white = imagecolorallocate($im, 255, 255, 255);
    $d = (int) round($size * 0.40);                                  // the die's side
    $x0 = (int) round(($size - $d) / 2); $y0 = $x0;
    $pin = max(2, (int) round($size * 0.05));
    imagesetthickness($im, $pin);
    foreach ([0.30, 0.50, 0.70] as $f) {
        $p = (int) round($x0 + ($d - 1) * ($f - 0.30) / 0.40);
        imageline($im, $p, (int) round($size * 0.14), $p, $y0, $white);
        imageline($im, $p, $y0 + $d, $p, (int) round($size * 0.86), $white);
        imageline($im, (int) round($size * 0.14), $p, $x0, $p, $white);
        imageline($im, $x0 + $d, $p, (int) round($size * 0.86), $p, $white);
    }
    imagesetthickness($im, 1);
    imagefilledrectangle($im, $x0, $y0, $x0 + $d, $y0 + $d, $white);
    $c = (int) round($d * 0.30);
    imagefilledrectangle($im, $x0 + $c, $y0 + $c, $x0 + $d - $c, $y0 + $d - $c, $yellow);
    return $im;
}
foreach (['favicon.png' => 64, 'logo-abbr.png' => 128, 'apple-touch-icon.png' => 180, 'icon-192.png' => 192, 'icon-512.png' => 512] as $file => $size) {
    $im = mark($size, $file !== 'apple-touch-icon.png');
    if ($file === 'apple-touch-icon.png') {                                   // iOS rounds it itself: an opaque square
        $flat = imagecreatetruecolor($size, $size);
        imagefill($flat, 0, 0, imagecolorallocate($flat, ...$indigo));
        imagecopy($flat, $im, 0, 0, 0, 0, $size, $size);
        $im = $flat;
    }
    imagepng($im, $dir . '/' . $file);
}
// the full logo: the mark and the name
$w = 420; $h = 90;
$im = imagecreatetruecolor($w, $h);
imagesavealpha($im, true);
imagealphablending($im, false);
imagefill($im, 0, 0, imagecolorallocatealpha($im, 0, 0, 0, 127));
imagealphablending($im, true);
$m = mark(70);
imagecopy($im, $m, 4, 10, 0, 0, 70, 70);
$dark = imagecolorallocate($im, 33, 37, 41);
imagettftext($im, 21, 0, 86, 55, $dark, $font, 'Sovereign LLM Manager');
imagepng($im, $dir . '/logo-full.png');
echo "brand images drawn in $dir\n";
