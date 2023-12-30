FROM python:3.12-alpine3.18

LABEL org.opencontainers.image.url=https://github.com/corey-braun/hybrid-cloud-email

## Install required packages
RUN set -eux; \
	apk add --no-cache \
		tini \
		postfix \
		postfix-pcre \
	; \
	pip install --no-cache-dir \
		boto3

## Add python files
WORKDIR /srv/app
COPY app .

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["./entrypoint.py"]
