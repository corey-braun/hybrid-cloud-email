#!/usr/bin/env bash
## Postconf commands applied on image build

set -e
## Log to stdout
postconf -e 'maillog_file=/dev/stdout'

## SSL cert config
postconf -e 'smtpd_tls_cert_file=/srv/cert.pem' \
    'smtpd_tls_key_file=/srv/key.pem'

## SMTP relay config
postconf -e 'smtp_sasl_auth_enable=yes' \
    'smtp_tls_security_level=encrypt' \
    'smtp_sasl_tls_security_options=noanonymous'

## Enable submission service; Auth from dovecot SASL
postconf -M 'submission/inet=submission inet n - n - - smtpd'
postconf -P 'submission/inet/syslog_name=postfix/submission' \
    'submission/inet/smtpd_tls_security_level=encrypt' \
    'submission/inet/smtpd_sasl_auth_enable=yes' \
    'submission/inet/smtpd_sasl_type=dovecot' \
    'submission/inet/smtpd_sasl_security_options=noanonymous' \
    'submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject' \
    'submission/inet/smtpd_recipient_restrictions=reject_non_fqdn_recipient,reject_unknown_recipient_domain,permit_sasl_authenticated,reject' \
    'submission/inet/smtpd_tls_auth_only=yes' \
    'submission/inet/local_header_rewrite_clients=static:all'

## Generate aliases db
newaliases
set +e
