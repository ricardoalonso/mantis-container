<?php
# Liveness endpoint: proves Apache is serving and PHP-FPM is executing PHP.
#
# Deliberately does NOT touch MantisBT or the database. A liveness probe that
# fails when the database is down makes the orchestrator restart every MantisBT
# pod in a loop, which fixes nothing. Use <context>/login_page.php as the
# readiness probe for "MantisBT can serve users". See README-usage.md.
header( 'Content-Type: text/plain' );
header( 'Cache-Control: no-store' );
echo "ok\n";
?>