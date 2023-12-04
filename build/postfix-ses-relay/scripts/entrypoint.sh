#!/bin/bash

REQUIRED_ENV_VARS=(AWS_CREDENTIALS AWS_REGION SASL_SERVER MAX_MESSAGE_SIZE)
declare -A ENV_VAR_DEFAULTS
ENV_VAR_DEFAULTS[MAX_MESSAGE_SIZE]=10485760 ## 10MiB, SES default max

. common.sh

join_by_char() {
    local IFS="$1"
    shift
    echo "$*"
}

## Set/check env vars
set_env_vars "${REQUIRED_ENV_VARS[@]}"
RELAYHOST="email-smtp.$AWS_REGION.amazonaws.com:587"
SMTP_CREDENTIALS_FILE=/etc/postfix/aws_smtp_credentials

## Create default login map if one isn't specified; Use no login map if value of SENDER_LOGIN_MAP is 'none' (not case sensitive)
if [ "${SENDER_LOGIN_MAP,,}" != 'none' ]; then
    if [ -n "$SENDER_LOGIN_MAP" ]; then
        postconf -P "submission/inet/smtpd_sender_login_maps=$SENDER_LOGIN_MAP"
    else
        set_env_vars SENDER_DOMAINS
        escaped_sender_domains="$(sed 's/\./\\\\\./g' <<< "$SENDER_DOMAINS")"
        IFS=', ' read -a allowed_domains <<< "$escaped_sender_domains"
        allowed_domains_string=$(join_by_char '|' "${allowed_domains[@]}")
        echo -n "/^([^+@]*)(\+[^@]*)?@($allowed_domains_string)$/   \${1}" > /etc/postfix/sender_login_map
        if [ -n "$WILDCARD_SENDER" ]; then
            echo -n ",$WILDCARD_SENDER" >> /etc/postfix/sender_login_map
        fi
        echo >> /etc/postfix/sender_login_map
        postconf -P 'submission/inet/smtpd_sender_login_maps=pcre:/etc/postfix/sender_login_map'
    fi
    postconf -P 'submission/inet/smtpd_sender_restrictions=reject_sender_login_mismatch'
fi

## Create AWS SMTP credentials from access key
IFS=':' read ACCESS_KEY SECRET_ACCESS_KEY <<< "$AWS_CREDENTIALS"
[ -z "$ACCESS_KEY" -o -z "$SECRET_ACCESS_KEY" ] && log_exit 'Failed to find access key and secret access key while parsing AWS credentials'
echo -n "$RELAYHOST $ACCESS_KEY:" > "$SMTP_CREDENTIALS_FILE"
smtp_credentials_generate.py "$SECRET_ACCESS_KEY" "$AWS_REGION" >> "$SMTP_CREDENTIALS_FILE"
[ $? -ne 0 ] && log_exit 'Failed to convert AWS secret access key and region to SMTP password'

## Set dovecot SASL address
postconf -P "submission/inet/smtpd_sasl_path=inet:$SASL_SERVER"

## Configure SES as relayhost
postconf -e "relayhost=$RELAYHOST"
postmap "$SMTP_CREDENTIALS_FILE"
chown root:root "$SMTP_CREDENTIALS_FILE" "$SMTP_CREDENTIALS_FILE.lmdb"
chmod 400 "$SMTP_CREDENTIALS_FILE" "$SMTP_CREDENTIALS_FILE.lmdb"
postconf -e 'smtp_sasl_password_maps=lmdb:/etc/postfix/aws_smtp_credentials'

## Set max message size
postconf -e "message_size_limit=$MAX_MESSAGE_SIZE"

## Start postfix foreground process
exec postfix start-fg
