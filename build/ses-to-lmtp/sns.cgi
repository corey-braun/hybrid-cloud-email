#!/usr/bin/env python3
import os
import sys
import subprocess
import urllib.request
import json

mail_script = 'process-new-mail.py'

def main():
    print("Content-Type: text/plain", end="\n\n")
    post_body = sys.stdin.read()
    post_data = json.loads(post_body)
    message_type = os.environ['HTTP_X_AMZ_SNS_MESSAGE_TYPE']
    topic_arn = os.environ['HTTP_X_AMZ_SNS_TOPIC_ARN']
    match message_type:
        case "Notification":
            print("Status: 200 OK")
            subprocess.run(mail_script, stdout=sys.stderr.buffer)
        case "SubscriptionConfirmation":
            with urllib.request.urlopen(post_data['SubscribeURL']) as response:
                subscription_status = response.read()
            print(f"Subscribed to SNS topic '{topic_arn}'", file=sys.stderr)
            print("Status: 200 OK")
        case "UnsubscribeConfirmation":
            print(f"Unsubscribed from SNS topic '{topic_arn}'", file=sys.stderr)
            print("Status: 200 OK")
        case _:
            raise ValueError(f"Unknown SNS message type: {message_type}")

if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Status: 400 Bad Request")
        raise
