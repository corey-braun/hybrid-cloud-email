#!/usr/bin/env python3
import os
import sys
import signal
import logging
import threading

import boto3
import botocore.exceptions
import email
import smtplib
import subprocess
import urllib.request
import http.server
from http import HTTPStatus

import ssl
import json
import base64
import functools

class SNSEndpointHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1" ## Required for SNS HTTPS endpoint
    timeout = 30

    def send_response(self, code, message=None):
        """Direct copy of parent class's method, but doesn't send 'Server' header to clients."""
        self.log_request(code)
        self.send_response_only(code, message)
        #self.send_header('Server', self.version_string())
        self.send_header('Date', self.date_time_string())

    def __init__(self, *args, basic_auth_credentials, message_handler=None, **kwargs):
        """Sets auth_key variable to check client 'Authorization' header value against, then invokes parent class's __init__() method."""
        self.auth_key = base64.b64encode(basic_auth_credentials.encode()).decode()
        self.message_handler = message_handler
        super().__init__(*args, **kwargs)

    def send_status(self, code, additional_headers={}):
        """Given an HTTP status code, sends the client appropriate response headers and body to indicate request status.
        Optionally, additional headers to send the client may be provided as a dict."""
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain')
        for k, v in additional_headers.items():
            self.send_header(k, v)
        content = f"{code} {HTTPStatus(code).phrase}\n".encode()
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def authenticate_client(self):
        """Checks if the client's 'Authorization' header value matches auth_key (encoded from basic_auth_credentials init argument).
        If the auth header is not provided, or has an incorrect value, sends a 401 response with 'WWW-Authenticate' header.
        Boolean return value indicates client authentication status."""
        if self.headers['Authorization'] == 'Basic ' + self.auth_key:
            return True
        self.send_status(401, {'WWW-Authenticate': 'Basic realm="sns"'})
        return False

    def do_HEAD(self):
        """HTTP HEAD method.
        Not required for SNS message delivery, but can be useful when testing endpoint availability."""
        if self.authenticate_client():
            self.send_status(200)

    def do_GET(self):
        """HTTP GET method.
        Not required for SNS message delivery, but can be useful when testing endpoint availability."""
        if self.authenticate_client():
            self.send_status(200)

    def do_POST(self):
        """HTTP POST method.
        Handles SNS notifications based on the message type indicated."""
        length = self.headers['Content-Length']
        if length:
            post_body = self.rfile.read(int(length))
        if self.authenticate_client():
            try:
                notification = json.loads(post_body)
                match notification['Type']:
                    case 'Notification':
                        try:
                            self.message_handler(notification['Message'])
                        except TypeError:
                            if not self.message_handler:
                                logging.error("Received SNS notification message, but no message handler is configured")
                            raise
                        ## Typically an exception would happen here due to misconfiguration, so while we couldn't process the message this time, we may be able to later.
                        ## By sending a status of code outside the 2XX-4XX range, we're telling SNS to consider notification delivery a failure.
                        ## This means the notification will be sent to the dead letter queue, giving us a chance to retry later.
                        except Exception:
                            logging.error("Processing of SNS notification failed")
                            self.send_status(500)
                            return
                    case 'SubscriptionConfirmation':
                        with urllib.request.urlopen(notification['SubscribeURL']) as response:
                            response.read()
                        logging.info(f"Subscribed to SNS topic '{notification['TopicArn']}'")
                    case 'UnsubscribeConfirmation':
                        logging.info(f"Unsubscribed from SNS topic '{notification['TopicArn']}'")
                    case _:
                        raise ValueError(f"Unknown SNS message type: '{notification['Type']}'")
            except Exception:
                self.send_status(400)
                raise
            else:
                self.send_status(200)

class S3MailProcessor:

    def __init__(self, s3_client, postfix_lookup_table, lmtp_address):
        self.s3 = s3_client
        self.postfix_lookup_table = postfix_lookup_table
        self.lmtp_host, self.lmtp_port = lmtp_address.rsplit(':', 1)

    def deliver_email_message(self, msg, recipients):
        """Deliver email.message.Message object to LMTP server."""
        with smtplib.LMTP(self.lmtp_host, self.lmtp_port) as server:
            server.send_message(msg, from_addr=msg['Return-Path'], to_addrs=recipients)

    def translate_email_addresses(self, addresses):
        """Use postfix's postmap utility to translate a list of email addresses to local account usernames.
        Only one instance of each username is included in the returned list, even if multiple addresses resolve to the same username.
        If none of the provided addresses return a username when looked up, an exception is raised."""
        users = set()
        for address in addresses:
            lookup_result = subprocess.run(['postmap', '-q', address, self.postfix_lookup_table], capture_output=True)
            user = lookup_result.stdout.decode().rstrip()
            if user:
                users.add(user)
            else:
                logging.warning(f"Postmap lookup for email address '{address}' returned no result")
        if not users:
            raise ValueError("None of the provided addresses returned a local account username")
        return list(users)

    def process_s3_email(self, bucket, key, to_addrs=None):
        """Process S3 email message object.
        If a list of recipient addresses is not provided, the recipient list is guessed from the email's headers.
        If the email is successfully delivered via LMTP, its S3 object is deleted."""
        try:
            s3_kwargs = {'Bucket': bucket, 'Key': key}
            msg = email.message_from_bytes(self.s3.get_object(**s3_kwargs)['Body'].read())
            if not to_addrs:
                to_fields = [f for f in (msg['To'], msg['Cc'], msg['Bcc']) if f is not None]
                to_addrs = [a[1] for a in email.utils.getaddresses(to_fields)]
            recipients = self.translate_email_addresses(to_addrs)
            self.deliver_email_message(msg, recipients)
        except Exception:
            logging.exception(f"Error processing email object '{key}' in bucket '{bucket}':")
            raise
        else:
            self.s3.delete_object(**s3_kwargs)
            logging.debug(f"Finished processing email object '{key}' in bucket '{bucket}'")

    def process_notification_message(self, message):
        """Parse and handle a S3 mail delivery SNS notification message.
        This message can be given in the form of a dict or a JSON-formatted string.
        Calls process_s3_email method with arguments from notification message."""
        try:
            try:
                message = json.loads(message)
            except TypeError:
                if not isinstance(message, dict):
                    raise
            bucket = message['receipt']['action']['bucketName']
            key = message['receipt']['action']['objectKey']
            recipients = message['receipt']['recipients']
        except Exception:
            logging.exception("Notification message parsing failed:")
            raise
        self.process_s3_email(bucket, key, recipients)

def get_env(var, **kwargs):
    """Get the value of an environment variable.
    If the environment variable is unset, checks again with the suffix '_FILE' added.
    If the file environment variable is set, returns the contents of the specified file, with any trailing whitespace stripped.
    If both of these environment variables are unset, returns value of kwarg 'default' if provided, otherwise raises a KeyError."""
    file_var = var + '_FILE'
    try:
        return os.environ[var]
    except KeyError:
        pass
    try:
        with open(os.environ[file_var]) as f:
            return f.read().rstrip()
    except KeyError:
        pass
    except Exception:
        logging.exception(f"Error reading file specified in environment variable '{file_var}':")
        raise
    try:
        return kwargs['default']
    except KeyError:
        pass
    raise KeyError(f"Environment variable '{var}[_FILE]' is unset")

def get_boto3_session(access_key, secret_access_key):
    """Given AWS IAM credentials, return a boto3 session.
    Credentials are validated using the STS GetCallerIdentity API call."""
    session = boto3.session.Session(access_key, secret_access_key)
    try:
        sts = session.client('sts')
        sts.get_caller_identity()
    except botocore.exceptions.ClientError as e:
        raise ValueError("Invalid or expired AWS credentials") from e
    return session

def queue_processing_thread_worker(queue, mail_processor, stop_event, run_interval):
    """Process new mail notifications in SQS queue on thread start, then again every run_interval seconds.
    When stop_event is set, finishes current operation then exits cleanly."""
    while True:
        successes = 0
        failures = 0
        while True:
            if stop_event.is_set():
                break
            try:
                messages = queue.receive_messages(
                    WaitTimeSeconds=10, ## Long polling to reduce false empty responses
                    VisibilityTimeout=3600, ## Don't return the same message more than once per hour
                    MaxNumberOfMessages=10
                    )
                if not messages:
                    break
            except Exception:
                logging.exception("Error polling for new SQS messages:")
                break
            for msg in messages:
                if stop_event.is_set():
                    break
                try:
                    mail_processor.process_notification_message(json.loads(msg.body)['Message'])
                except botocore.exceptions.ClientError as e:
                    if e.response['Error']['Code'] == 'NoSuchKey':
                        logging.error("Specified S3 object key does not exist, deleting notification")
                    else:
                        raise
                except Exception:
                    logging.error("Notification handling failed")
                    failures += 1
                    continue
                try:
                    msg.delete()
                    successes += 1
                except Exception:
                    logging.exception("Error deleting processed notification from queue")
        total_messages = successes + failures
        if total_messages:
            logging.info(f"Finished processing {total_messages} SQS messages:\n{successes} processed and deleted successfully.\n{failures} failed to process and will be retried.")
        if stop_event.wait(run_interval):
            break
    logging.debug("Queue processing thread exiting")

def serve_endpoint(basic_auth_credentials, message_handler=None, port=443, ssl_cert='/srv/cert.pem', ssl_key='/srv/key.pem'):
    """Configure SNS HTTPS endpoint, then start it with serve_forever method."""
    if not message_handler:
        logging.warning("No notification message processing method is available; SNS endpoint will handle subscription-related notifications only.")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(ssl_cert, ssl_key)
    handler = functools.partial(SNSEndpointHandler, basic_auth_credentials=basic_auth_credentials, message_handler=message_handler)
    httpd = http.server.ThreadingHTTPServer(('', port), handler)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    logging.info("Starting SNS HTTPS endpoint")
    httpd.serve_forever()

def main():
    ## Shutdown signal event to notify threads they should exit
    shutdown_event = threading.Event()

    ## Shutdown signal handler function
    def shutdown_signal_handler(signal, frame):
        logging.debug("Received shutdown signal")
        shutdown_event.set()
        sys.exit(0)

    ## Trigger shutdown upon receiving SIGTERM
    signal.signal(signal.SIGTERM, shutdown_signal_handler)

    ## Configure logging
    log_level_name = get_env('LOG_LEVEL', default='INFO')
    log_level = getattr(logging, log_level_name.upper(), None)
    if not isinstance(log_level, int):
        raise ValueError(f"Invalid value for environment variable 'LOG_LEVEL': '{log_level_name}'")
    logging.basicConfig(
        stream=sys.stdout,
        format='%(asctime)s %(levelname)s - %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S',
        level=log_level
        )
    ## Don't output exception tracebacks unless debug logging is enabled
    if log_level > logging.DEBUG:
        sys.tracebacklimit = 0

    ## Set up S3 mail processor
    try:
        session = get_boto3_session(*get_env('AWS_CREDENTIALS').split(':', 1))
        s3_client = session.client('s3')
        mail_processor = S3MailProcessor(
            s3_client,
            get_env('POSTFIX_LOOKUP_TABLE'),
            get_env('LMTP_ADDRESS')
            )
        message_handler = mail_processor.process_notification_message
    except Exception:
        message_handler = None
        logging.exception("Mail processor configuration failed:")
    else:
        ## Start dead letter queue processing thread
        try:
            sqs = session.resource('sqs', region_name=get_env('AWS_REGION'))
            queue = sqs.Queue(get_env('DEAD_LETTER_QUEUE_URL'))
            dlq_processing_thread = threading.Thread(
                target=queue_processing_thread_worker,
                args=(
                    queue,
                    mail_processor,
                    shutdown_event,
                    int(get_env('DEAD_LETTER_QUEUE_CHECK_INTERVAL', default=21600))
                    )
                )
            logging.info("Starting dead letter queue processing thread")
            dlq_processing_thread.start()
        except Exception:
            logging.exception("Error starting dead letter queue processing thread:")
            logging.warning("Dead letter queue processing thread is not running; SNS endpoint will function normally, but missed notifications will not be retried.")

    ## Serve SNS HTTPS endpoint
    try:
        serve_endpoint(
            get_env('BASIC_AUTH_CREDENTIALS'),
            message_handler
            )
    except Exception:
        logging.critical("Failed to start SNS endpoint:")
        logging.exception()
        signal.raise_signal(signal.SIGTERM)

if __name__ == "__main__":
    main()