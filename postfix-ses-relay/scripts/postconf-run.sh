#!/usr/bin/env bash
## Postconf commands applied on container run

set -e
## Set dovecot SASL address
postconf -P "submission/inet/smtpd_sasl_path=inet:$SASL_SERVER"

## Configure AWS SES as relayhost
postconf -e "relayhost=$RELAYHOST"
postmap /etc/postfix/aws_smtp_credentials
chown root:root /etc/postfix/aws_smtp_credentials /etc/postfix/aws_smtp_credentials.lmdb
chmod 400 /etc/postfix/aws_smtp_credentials /etc/postfix/aws_smtp_credentials.lmdb
postconf -e 'smtp_sasl_password_maps=lmdb:/etc/postfix/aws_smtp_credentials'

## Set max message size
postconf -e "message_size_limit=$MAX_MESSAGE_SIZE"
set +e
