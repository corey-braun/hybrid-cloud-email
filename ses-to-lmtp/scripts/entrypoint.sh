#!/bin/bash

REQUIRED_ENV_VARS=(SNS_SHARED_CREDENTIALS_FILE AWS_SHARED_CREDENTIALS_FILE SNS_CREDENTIALS AWS_CREDENTIALS MAIL_BUCKET DELETE_PROCESSED_MAIL DEBUG_MODE)
declare -A ENV_VAR_DEFAULTS
ENV_VAR_DEFAULTS[SNS_SHARED_CREDENTIALS_FILE]=/srv/sns_credentials
ENV_VAR_DEFAULTS[AWS_SHARED_CREDENTIALS_FILE]=/srv/aws_credentials
ENV_VAR_DEFAULTS[DEBUG_MODE]='false'
ENV_VAR_DEFAULTS[DELETE_PROCESSED_MAIL]='false'

log_exit() {
    echo "Error: $1" >&2
    exit 1
}

set_env_vars() {
    for var in "$@"; do
        local file_var="${var}_FILE"
        if [ -n "${!var}" -a -n "${!file_var}" ]; then
            log_exit "Variables '$var' and '$file_var' are mutually exclusive"
        elif [ -z "${!var}" -a -z "${!file_var}" -a -n "${ENV_VAR_DEFAULTS[$var]}" ]; then
            export "$var"="${ENV_VAR_DEFAULTS[$var]}"
        elif [ -z "${!var}" ]; then
            if [ -n "${file_var}" -a -r "${!file_var}" ]; then
                export "$var"="$(< "${!file_var}")"
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

chown_apache_user() {
    chown www-data:www-data "$1"
    chmod 600 "$1"
}

## Set/check env vars
set_env_vars "${REQUIRED_ENV_VARS[@]}"

## Create SNS_SHARED_CREDENTIALS_FILE for apache basic auth to SNS endpoint
echo "$SNS_CREDENTIALS" > "$SNS_SHARED_CREDENTIALS_FILE"
chown_apache_user "$SNS_SHARED_CREDENTIALS_FILE"

## Create AWS_SHARED_CREDENTIALS_FILE for Boto3 auth
IFS=':' read key secret_key <<< "$AWS_CREDENTIALS"
[ -z "$key" -o -z "$secret_key" ] && log_exit "Error parsing AWS credentials"
echo -e "[default]\naws_access_key_id=$key\naws_secret_access_key=$secret_key" > "$AWS_SHARED_CREDENTIALS_FILE"
chown_apache_user "$AWS_SHARED_CREDENTIALS_FILE"

## Move mail at startup; Script should only exit non-zero due to a configuration error, so stop the container if it does
/srv/scripts/process-new-mail.py || exit 1

## Start apache foreground process
exec httpd-foreground
