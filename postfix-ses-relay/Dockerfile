FROM alpine:3.18.4

## Install required packages
RUN apk add --no-cache bash python3 ca-certificates postfix postfix-pcre cyrus-sasl tini

## Set default environment variables
ENV MAX_MESSAGE_SIZE 10485760

## Add scripts
COPY scripts /srv/scripts/

## Run build-time configuration commands
RUN /srv/scripts/postconf-build.sh

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/srv/scripts/entrypoint.sh"]
