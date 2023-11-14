#!/bin/bash

FILE_ENV_VARS=(AWS_CREDENTIALS MAIL_BUCKET SNS_CREDENTIALS)
REQUIRED_ENV_VARS=()

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

chown_user() {
    chown www-data:www-data "$1"
    chmod 600 "$1"
}

## Set/check env vars
set_file_vars "${FILE_ENV_VARS[@]}"
check_vars_set "${REQUIRED_ENV_VARS[@]}"
export SNS_SHARED_CREDENTIALS_FILE=/srv/sns_credentials \
       AWS_SHARED_CREDENTIALS_FILE=/srv/aws_credentials

## Create SNS credentials file readable by unprivileged user
echo "$SNS_CREDENTIALS" > "$SNS_SHARED_CREDENTIALS_FILE"
chown_user "$SNS_SHARED_CREDENTIALS_FILE"

## Set up AWS credentials for use with AWS CLI
IFS=':' read key secret_key <<< "$AWS_CREDENTIALS"
[ -z "$key" -o -z "$secret_key" ] && log_exit "Error parsing AWS credentials"
echo -e "[default]\naws_access_key_id=$key\naws_secret_access_key=$secret_key" > "$AWS_SHARED_CREDENTIALS_FILE"
chown_user "$AWS_SHARED_CREDENTIALS_FILE"

## Move mail at startup
/srv/scripts/process-new-mail.py

## Start apache foreground process
exec httpd-foreground
