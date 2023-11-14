#!/bin/bash

FILE_ENV_VARS=(AWS_CREDENTIALS AWS_REGION SASL_SERVER)
REQUIRED_ENV_VARS=(MAX_MESSAGE_SIZE)

log_exit() {
    echo "Error: $1" >&2
    exit 1
}

set_file_vars() {
    for var in "$@"; do
        local file_var="${var}_FILE"
        if [ -n "${!var}" -a -n "${!file_var}" ]; then
            log_exit "Variables '$var' and '$file_var' are mutually exclusive"
        elif [ -z "${!var}" ]; then
            if [ -n "${file_var}" -a -r "${!file_var}" ]; then
                export "$var"="$(< ${!file_var})"
            elif [ -z "${!file_var}" ]; then
                log_exit "Required variable '$var[_FILE]' is unset"
            elif [ -f "${!file_var}" ]; then
                log_exit "File specified in '$file_var' is not readable"
            else
                log_exit "Couldn't find file specified in '$file_var'"
            fi
        fi
    done
}

check_vars_set() {
    for var in "$@"; do
        if [ -z "${!var}" ]; then
            log_exit "Required variable '$var' is unset"
        fi
    done
}

join_by_char() {
    local IFS="$1"
    shift
    echo "$*"
}

## Set/check env vars
set_file_vars "${FILE_ENV_VARS[@]}"
check_vars_set "${REQUIRED_ENV_VARS[@]}"
RELAYHOST="email-smtp.$AWS_REGION.amazonaws.com:587"
SMTP_CREDENTIALS_FILE=/etc/postfix/aws_smtp_credentials

## Create default login map if one isn't specified; Use no login map if value of SENDER_LOGIN_MAP is 'none' (not recommended)
if [ "${SENDER_LOGIN_MAP,,}" != 'none' ]; then
    if [ -z "$SENDER_LOGIN_MAP" ]; then
        check_vars_set SENDER_DOMAINS
        escaped_sender_domains="$(sed 's/\./\\\\\./g' <<< "$SENDER_DOMAINS")"
        IFS=', ' read -a allowed_domains <<< "$escaped_sender_domains"
        allowed_domains_string=$(join_by_char '|' "${allowed_domains[@]}")
        echo -n "/^([^+@]*)(\+[^@]*)?@($allowed_domains_string)$/   \${1}" > /etc/postfix/sender_login_map
        if [ -n "$WILDCARD_SENDER" ]; then
            echo -n ",$WILDCARD_SENDER" >> /etc/postfix/sender_login_map
        fi
        echo >> /etc/postfix/sender_login_map
        postconf -P 'submission/inet/smtpd_sender_login_maps=pcre:/etc/postfix/sender_login_map'
    else
        postconf -P "submission/inet/smtpd_sender_login_maps=$SENDER_LOGIN_MAP"
    fi
    postconf -P 'submission/inet/smtpd_sender_restrictions=reject_sender_login_mismatch'
fi

## Create AWS SMTP credentials from access key
IFS=':' read ACCESS_KEY SECRET_ACCESS_KEY <<< "$AWS_CREDENTIALS"
[ -z "$ACCESS_KEY" -o -z "$SECRET_ACCESS_KEY" ] && log_exit 'Failed to find access key and secret access key while parsing AWS_CREDENTIALS[_FILE]'
echo -n "$RELAYHOST $ACCESS_KEY:" > "$SMTP_CREDENTIALS_FILE"
/srv/scripts/smtp_credentials_generate.py "$SECRET_ACCESS_KEY" "$AWS_REGION" >> "$SMTP_CREDENTIALS_FILE"
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
