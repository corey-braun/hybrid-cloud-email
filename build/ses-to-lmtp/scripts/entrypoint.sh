#!/bin/bash

REQUIRED_ENV_VARS=(SNS_SHARED_CREDENTIALS_FILE AWS_SHARED_CREDENTIALS_FILE SNS_CREDENTIALS AWS_CREDENTIALS LMTP_ADDRESS MAIL_BUCKET DELETE_PROCESSED_MAIL DEBUG_MODE)
declare -A ENV_VAR_DEFAULTS
ENV_VAR_DEFAULTS[SNS_SHARED_CREDENTIALS_FILE]=/srv/sns_credentials
ENV_VAR_DEFAULTS[AWS_SHARED_CREDENTIALS_FILE]=/srv/aws_credentials
ENV_VAR_DEFAULTS[DEBUG_MODE]='false'
ENV_VAR_DEFAULTS[DELETE_PROCESSED_MAIL]='false'

. common.sh

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
process-new-mail.py || exit 1

## Start apache foreground process
exec httpd-foreground
