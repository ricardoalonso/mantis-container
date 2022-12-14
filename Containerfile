FROM quay.io/rockylinux/rockylinux:9
MAINTAINER Ricardo Alonso <ricardoalonsos@gmail.com>
LABEL description="Mantis bug tracker version 2.25.5 running on Apache 2.4 and PHP 8.1+PHP FPM"
EXPOSE 8080/tcp 8443/tcp
ENV MANTIS_VERSION=2.25.5 \
    MANTIS_CONFIG_FOLDER=/mantis/config/ \
    MANTIS_ADMINISTRATION_ENABLED=true \
    PHP_VERSION=8.1 \
    PHP_UPLOAD_MAX_FILESIZE=4M \
    PHP_MEMORY_LIMIT=1024M \
    PHP_DISPLAY_ERRORS=Off \
    PHP_MAX_EXECUTION_TIME=30 \
    HTTPD_REQUEST_TIMEOUT=300
RUN dnf module enable -y php:$PHP_VERSION && \
    INSTALL_PKGS="php php-mysqlnd php-pgsql php-bcmath openssl \
                  php-gd php-intl php-ldap php-mbstring php-pdo \
                  php-process php-soap php-opcache php-xml \
                  php-gmp php-pecl-apcu php-pecl-zip mod_ssl hostname \
                  patch " && \
    dnf install -y --setopt=tsflags=nodocs $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    dnf clean all --enablerepo='*' && \
    rm -rf /var/cache/dnf /var/log/dnf*
WORKDIR /var/www/html/
ADD ./bin /usr/local/bin
ADD ./patches ./patches
ADD ./conf.d /etc/httpd/conf.d
RUN install-mantis.sh
USER apache
CMD ["run.sh"]
VOLUME ["/mantis/config","/mantis/attachments"]
