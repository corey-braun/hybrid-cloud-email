FROM python:3.12-alpine3.18

LABEL org.opencontainers.image.url=https://github.com/corey-braun/hybrid-cloud-email

## Install required packages
RUN apk add --no-cache postfix postfix-pcre \
	&& pip install --no-cache-dir boto3

## Add scripts
COPY scripts /usr/local/bin/

CMD ["entrypoint.py"]
