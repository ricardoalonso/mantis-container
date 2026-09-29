# MantisBT on Apache 2.4 + PHP-FPM, on Rocky Linux 9.
#
# The base image is pinned by digest so that a given commit builds the same
# image tomorrow as it does today. Bump it deliberately:
#   podman pull quay.io/rockylinux/rockylinux:9
#   podman inspect quay.io/rockylinux/rockylinux:9 --format '{{index .RepoDigests 0}}'
FROM quay.io/rockylinux/rockylinux@sha256:8101994123cf3d0a8fee517bee7f39e555c7d92bd2d9eb3303cc988a0eeed00f

# MANTIS_VERSION is an ARG so build.sh can read it back and tag the image to
# match, rather than the version being repeated in several places and drifting.
ARG MANTIS_VERSION=2.28.4
ARG PHP_VERSION=8.1

LABEL maintainer="Ricardo Alonso <ricardoalonsos@gmail.com>" \
      description="MantisBT ${MANTIS_VERSION} running on Apache 2.4 and PHP ${PHP_VERSION} + PHP-FPM" \
      org.opencontainers.image.title="mantisbt" \
      org.opencontainers.image.version="${MANTIS_VERSION}" \
      org.opencontainers.image.source="https://github.com/ricardoalonso/mantis-container"

EXPOSE 8080/tcp 8443/tcp

ENV MANTIS_VERSION=${MANTIS_VERSION} \
    PHP_VERSION=${PHP_VERSION} \
    MANTIS_CONFIG_FOLDER=/mantis/config/ \
    MANTIS_ADMINISTRATION_ENABLED=true \
    PHP_UPLOAD_MAX_FILESIZE=4M \
    PHP_MEMORY_LIMIT=1024M \
    PHP_DISPLAY_ERRORS=Off \
    PHP_MAX_EXECUTION_TIME=30 \
    PHP_OPCACHE_VALIDATE_TIMESTAMPS=On \
    HTTPD_REQUEST_TIMEOUT=300

RUN dnf module enable -y php:$PHP_VERSION && \
    INSTALL_PKGS="php php-mysqlnd php-pgsql php-bcmath openssl \
                  php-gd php-intl php-ldap php-mbstring php-pdo \
                  php-process php-soap php-opcache php-xml php-fpm \
                  php-gmp php-pecl-apcu php-pecl-zip mod_ssl hostname \
                  patch procps-ng " && \
    dnf install -y --setopt=tsflags=nodocs $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    dnf clean all --enablerepo='*' && \
    rm -rf /var/cache/dnf /var/log/dnf*

WORKDIR /var/www/html/

# COPY rather than ADD: ADD also unpacks archives and fetches URLs, neither of
# which is wanted here.
COPY ./files /
# Only this version's patches, so the layer does not carry every other release's.
COPY ./patches/${MANTIS_VERSION}/ /build/patches/
COPY ./checksums.sha256 /build/checksums.sha256

RUN install-mantis.sh && rm -rf /build

USER apache
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD ["healthcheck.sh"]
CMD ["run.sh"]
VOLUME ["/mantis/config","/mantis/attachments"]
