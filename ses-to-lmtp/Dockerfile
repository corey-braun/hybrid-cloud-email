FROM httpd:2.4.58-alpine3.18

## Install required packages
RUN apk add --no-cache bash python3 py3-boto3 tini

## Set default environment variables
ENV AWS_SHARED_CREDENTIALS_FILE /srv/aws_credentials
ENV PROCESS_MAIL_AT_STARTUP true
ENV DELETE_PROCESSED_EMAILS false
ENV DEBUG_MODE false

## Add config files and scripts
COPY httpd.conf /usr/local/apache2/conf/
COPY httpd-ssl.conf /usr/local/apache2/conf/extra/
COPY sns.cgi /srv/cgi/
COPY scripts /srv/scripts/

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/srv/scripts/entrypoint.sh"]
