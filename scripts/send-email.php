<?php
// send-email.php - Send email via Grav email plugin
// Usage: php send-email.php to@example.com "Subject" "Body"

if ($argc < 4) {
    echo "Usage: php send-email.php <to> <subject> <body>\n";
    exit(1);
}

$to = $argv[1];
$subject = $argv[2];
$body = $argv[3];

// Load Grav
define('GRAV_ROOT', __DIR__ . '/../config/www');
require_once GRAV_ROOT . '/vendor/autoload.php';

use Grav\Common\Grav;

$grav = Grav::instance();
$grav->initialize();

try {
    $message = $grav['Email']->message()
        ->setSubject($subject)
        ->setBody($body)
        ->setFrom($grav['config']->get('site.author.email', 'noreply@example.com'))
        ->addTo($to);

    $sent = $grav['Email']->send($message);

    if ($sent) {
        echo "OK\n";
        exit(0);
    } else {
        echo "FAILED\n";
        exit(1);
    }
} catch (Exception $e) {
    echo "ERROR: " . $e->getMessage() . "\n";
    exit(1);
}
