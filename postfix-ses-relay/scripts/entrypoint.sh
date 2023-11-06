#!/bin/bash

FILE_ENV_VARS=(AWS_CREDENTIALS AWS_REGION)
REQUIRED_ENV_VARS=(MAX_MESSAGE_SIZE SASL_SERVER)

log_exit() {
    echo "Error: $1" >&2
    exit 1
}

set_file_vars() {
    for var in "$@"; do
        local file_var="${var}_FILE"
        if [ -z "${!var}" ]; then
            if [ -n "${file_var}" -a -r "${!file_var}" ]; then
                export "$var"="$(cat ${!file_var})"
            elif [ -f "${!file_var}" ]; then
                log_exit "File specified in '$file_var' is not readable"
            elif [ -z "${!file_var}" ]; then
                log_exit "Required variable $var[_FILE] is unset"
            else
                log_exit "Couldn't set variable '$var'"
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

## Create default login map if one isn't specified; Use no login map if value of SENDER_LOGIN_MAP is 'none' (not recommended)
if [ "${SENDER_LOGIN_MAP,,}" != 'none' ]; then
    if [ -z "$SENDER_LOGIN_MAP" ]; then
        check_vars_set ALLOWED_SENDER_DOMAINS
        escaped_sender_domains="$(sed -e 's/\./\\\\\./g' <<< "$ALLOWED_SENDER_DOMAINS")"
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
echo -n "$RELAYHOST $ACCESS_KEY:" > /etc/postfix/aws_smtp_credentials
/srv/scripts/smtp_credentials_generate.py "$SECRET_ACCESS_KEY" "$AWS_REGION" >> /etc/postfix/aws_smtp_credentials
[ $? -ne 0 ] && log_exit "Failed to convert AWS secret access key and region to SMTP password"

## Execute runtime postconf commands
. /srv/scripts/postconf-run.sh

## Start postfix foreground process
exec postfix start-fg
