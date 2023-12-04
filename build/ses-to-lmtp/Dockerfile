FROM httpd:2.4.58-alpine3.18

LABEL org.opencontainers.image.url=https://github.com/corey-braun/hybrid-cloud-email

## Install required packages
RUN apk add --no-cache bash python3 py3-boto3 tini

## Add scripts
COPY --from=common common.sh /usr/local/bin/
COPY scripts /usr/local/bin/
COPY sns.cgi /srv/cgi/

## Add config files
COPY httpd.conf /usr/local/apache2/conf/
COPY httpd-ssl.conf /usr/local/apache2/conf/extra/

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["entrypoint.sh"]
