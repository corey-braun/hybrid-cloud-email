#!/usr/bin/env python3
import os
import traceback
import smtplib
import email
import boto3

def env_to_bool(env_var):
    value=os.environ[env_var].lower()
    if value in ['true', 'yes']:
        return True
    elif value in ['false', 'no']:
        return False
    else:
        raise ValueError(f"Invalid value for boolean environment variable '{env_var}': '{value}'")

processed_prefix = 'processed/'
s3_bucket = os.environ['MAIL_BUCKET']
lmtp_host, lmtp_port = os.environ['LMTP_ADDRESS'].rsplit(':', 1)
lmtp_port = int(lmtp_port)
delete_processed_mail = env_to_bool('DELETE_PROCESSED_MAIL')
debug_mode = env_to_bool('DEBUG_MODE')

def main():
    new_emails = get_email_objects()
    if new_emails:
        process_emails(new_emails)
    elif debug_mode:
        print("Found no new emails")

def get_email_objects():
    client = boto3.client('s3')
    response = client.list_objects_v2(
    Bucket=s3_bucket,
    Delimiter=','
    )
    return [msg['Key'] for msg in response['Contents'] if not msg['Key'].startswith(processed_prefix) and not msg['Key'].endswith('/') and '/' in msg['Key']]

def process_emails(objects_list):
    s3 = boto3.resource('s3')
    with smtplib.LMTP(lmtp_host, lmtp_port) as server:
        for i in objects_list:
            try:
                reciever = i.split('/', 1)[0]
                msg = email.message_from_bytes(s3.Object(s3_bucket, i).get()['Body'].read())
                if 'Return-Path' in msg:
                    return_path = msg['Return-Path']
                    del msg['Return-Path']
                else:
                    print(f"Warning: No Return Path in message '{i}', using 'None'")
                    return_path = 'None'
                server.sendmail(return_path, reciever, msg.as_bytes())
            except Exception:
                print(f"Error handling object '{i}' in bucket '{s3_bucket}'\n{traceback.format_exc()}")
            else:
                try:
                    if not delete_processed_mail:
                        new_object = processed_prefix + i
                        s3.Object(s3_bucket, new_object).copy_from(CopySource={'Bucket': s3_bucket, 'Key': i})
                except Exception:
                    print(f"Error moving '{i}' to '{new_object}' in bucket '{s3_bucket}'\n{traceback.format_exc()}")
                else:
                    s3.Object(s3_bucket, i).delete()
                    if debug_mode:
                        print(f"Finished processing '{i}'")

if __name__ == '__main__':
    main()
