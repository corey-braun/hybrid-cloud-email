FROM alpine:3.18.4

LABEL org.opencontainers.image.url=https://github.com/corey-braun/hybrid-cloud-email

## Install required packages
RUN apk add --no-cache bash python3 ca-certificates postfix postfix-pcre cyrus-sasl tini

## Add scripts
COPY scripts /srv/scripts/

## Run build-time configuration commands
RUN /srv/scripts/postconf-build.sh

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/srv/scripts/entrypoint.sh"]
