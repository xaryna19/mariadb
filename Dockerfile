FROM alpine:3.20
LABEL maintainer="xaryna@gmail.com"
LABEL description="Alpine based image for mariadb"

# Setup apache and php
RUN apk --no-cache --update \
    add apk add --no-cache mariadb mariadb-client mariadb-server-utils \
        rm -f /var/cache/apk/*

EXPOSE 3306

ADD docker-entrypoint.sh /

HEALTHCHECK CMD wget -q --no-cache --spider localhost

RUN chmod +x docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
