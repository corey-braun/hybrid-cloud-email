#!/bin/bash

REQUIRED_ENV_VARS=(AWS_IAM_CREDENTIALS AWS_REGION SASL_ADDRESS POSTFIX_LOOKUP_TABLE MAX_MESSAGE_SIZE)
declare -A ENV_VAR_DEFAULTS
ENV_VAR_DEFAULTS[MAX_MESSAGE_SIZE]=10485760  # 10MiB, SES default max

. common.sh

# Set/check env vars
set_env_vars "${REQUIRED_ENV_VARS[@]}"
RELAYHOST="email-smtp.$AWS_REGION.amazonaws.com:587"
SMTP_CREDENTIALS_FILE=/etc/postfix/ses_smtp_credentials

# Set SASL address for submission service client authentication
postconf -P "submission/inet/smtpd_sasl_path=inet:$SASL_ADDRESS"

# Set submission service sender login map
postconf -P \
    "submission/inet/smtpd_sender_login_maps=$POSTFIX_LOOKUP_TABLE" \
    'submission/inet/smtpd_sender_restrictions=reject_sender_login_mismatch'

# Create and set permissions on SES SMTP credentials files
touch "$SMTP_CREDENTIALS_FILE" "$SMTP_CREDENTIALS_FILE.lmdb"
chown root:root "$SMTP_CREDENTIALS_FILE" "$SMTP_CREDENTIALS_FILE.lmdb"
chmod 600 "$SMTP_CREDENTIALS_FILE" "$SMTP_CREDENTIALS_FILE.lmdb"

# Generate SES SMTP credentials from IAM credentials
IFS=':' read access_key secret_access_key <<< "$AWS_IAM_CREDENTIALS"
[ -z "$access_key" -o -z "$secret_access_key" ] && log_exit 'Failed to find access key and secret access key while parsing AWS IAM credentials'
echo -n "$RELAYHOST $access_key:" > "$SMTP_CREDENTIALS_FILE"
smtp_credentials_generate.py "$secret_access_key" "$AWS_REGION" >> "$SMTP_CREDENTIALS_FILE"
[ $? -ne 0 ] && log_exit 'Failed to convert AWS secret access key and region to SMTP password'
postmap "$SMTP_CREDENTIALS_FILE"

# Configure SES as relayhost
postconf -e \
    "relayhost=$RELAYHOST" \
    "smtp_sasl_password_maps=lmdb:$SMTP_CREDENTIALS_FILE"

# Set max message size
postconf -e "message_size_limit=$MAX_MESSAGE_SIZE"

# Start postfix foreground process
exec postfix start-fg
