FROM alpine:3.18.4

LABEL org.opencontainers.image.url=https://github.com/corey-braun/hybrid-cloud-email

## Install packages and configure postfix
RUN set -eux; \
	apk add --no-cache \
		bash \
		python3 \
		ca-certificates \
		postfix \
		postfix-pcre \
		cyrus-sasl \
		tini \
	; \
	postconf -e \
		'maillog_file=/dev/stdout' \
		'smtpd_tls_cert_file=/srv/cert.pem' \
		'smtpd_tls_key_file=/srv/key.pem' \
		'smtp_sasl_auth_enable=yes' \
		'smtp_tls_security_level=encrypt' \
		'smtp_sasl_tls_security_options=noanonymous' \
	; \
	postconf -M \
		'submission/inet=submission inet n - n - - smtpd' \
	; \
	postconf -P \
		'submission/inet/smtpd_tls_security_level=encrypt' \
		'submission/inet/smtpd_sasl_auth_enable=yes' \
		'submission/inet/smtpd_sasl_type=dovecot' \
		'submission/inet/smtpd_sasl_security_options=noanonymous' \
		'submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject' \
		'submission/inet/smtpd_recipient_restrictions=reject_non_fqdn_recipient,reject_unknown_recipient_domain,permit_sasl_authenticated,reject' \
		'submission/inet/smtpd_tls_auth_only=yes' \
		'submission/inet/local_header_rewrite_clients=static:all' \
	; \
	newaliases

## Add scripts
COPY --from=common common.sh /usr/local/bin/
COPY scripts /usr/local/bin/

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["entrypoint.sh"]
