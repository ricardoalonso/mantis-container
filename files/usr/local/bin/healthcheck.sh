#!/bin/bash
# Liveness check for the HEALTHCHECK instruction.
#
# Checks that Apache is answering *and* that php-fpm is behind it: the URL is a
# PHP entry point, so a dead php-fpm gives a 502 and fails here. The previous
# version grepped "< HTTP/1.1 200" out of curl's verbose output, which broke on
# any change to that format or a switch to HTTP/2.
set -euo pipefail

curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:8080/mantis/login_page.php
