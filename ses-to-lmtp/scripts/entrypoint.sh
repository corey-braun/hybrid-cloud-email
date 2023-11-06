#!/bin/bash

FILE_ENV_VARS=(AWS_CREDENTIALS MAIL_BUCKET_NAME)
REQUIRED_ENV_VARS=(AWS_SHARED_CREDENTIALS_FILE SNS_CREDENTIALS_FILE)

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

## Set/check env vars
set_file_vars "${FILE_ENV_VARS[@]}"
check_vars_set "${REQUIRED_ENV_VARS[@]}"

## Set up AWS credentials for use with AWS CLI
IFS=':' read key secret_key <<< "$AWS_CREDENTIALS"
[ -z "$key" -o -z "$secret_key" ] && log_exit "Error parsing AWS credentials"
echo -e "[default]\naws_access_key_id=$key\naws_secret_access_key=$secret_key" > "$AWS_SHARED_CREDENTIALS_FILE"
chown www-data:www-data "$AWS_SHARED_CREDENTIALS_FILE"
chmod 600 "$AWS_SHARED_CREDENTIALS_FILE"

## Move mail at startup if enabled
if [ "${PROCESS_MAIL_AT_STARTUP,,}" = 'true' ]; then
    /srv/scripts/process-new-mail.py
fi

## Start apache in foreground
exec httpd-foreground
