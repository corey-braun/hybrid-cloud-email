FROM httpd:2.4.58-alpine3.18

## Install required packages
RUN apk add --no-cache bash python3 py3-boto3 tini

## Add scripts
COPY scripts /srv/scripts/
COPY sns.cgi /srv/cgi/

## Add config files
COPY httpd.conf /usr/local/apache2/conf/
COPY httpd-ssl.conf /usr/local/apache2/conf/extra/

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/srv/scripts/entrypoint.sh"]
