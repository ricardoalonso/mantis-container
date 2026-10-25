#!/bin/bash
# Liveness check for the HEALTHCHECK instruction.
#
# Requests /healthz.php, so it checks that Apache is answering *and* that
# php-fpm is behind it: a dead php-fpm gives a 502 and fails here. It does not
# touch the database on purpose -- a database outage must not get the container
# restarted. Readiness ("can MantisBT serve users") is <MANTIS_CONTEXT_PATH>/login_page.php;
# see README-usage.md.
set -euo pipefail

body=$(curl -fsS --max-time 5 http://127.0.0.1:8080/healthz.php)
[ "$body" = "ok" ]
