# hybrid-cloud-email
A Hybrid-Cloud email server built with AWS and Docker. By using [Amazon SES](https://aws.amazon.com/ses/) as a backend for sending and receiving emails, this solution provides an alternative to the typical challenges/roadblocks of self-hosting email, such as:
- Sender reputation
- Blocked ports
- Non-static IP

Since this solution uses an infrastructure as code design, it is extremely easy to [deploy](#deployment) using [Docker Compose](https://docs.docker.com/compose/) and [AWS CloudFormation](https://aws.amazon.com/cloudformation/). Please note that after deployment & testing, you must [manually request production access to SES](#moving-out-of-the-ses-sandbox) to remove certain restrictions.

Light personal use of this solution is typically very [cheap](#pricing) thanks to AWS's free tier offerings and prorated billing.

## Table of contents
- [hybrid-cloud-email](#hybrid-cloud-email)
  - [Table of contents](#table-of-contents)
  - [How it works](#how-it-works)
    - [Sending mail](#sending-mail)
    - [Receiving mail](#receiving-mail)
  - [Requirements](#requirements)
  - [Deployment](#deployment)
    - [Docker](#docker)
    - [AWS](#aws)
    - [Moving out of the SES sandbox](#moving-out-of-the-ses-sandbox)
  - [Pricing](#pricing)
    - [SES](#ses)
    - [SNS](#sns)
    - [SQS](#sqs)
    - [S3](#s3)

## How it works
Using Docker, you run an IMAP server, [Dovecot](https://www.dovecot.org/), and an SMTP server, [Postfix](https://www.postfix.org/).
These are the servers your email client interacts with to fetch/manage received mail and submit outgoing mail, respectively.

Behind the scenes, [Amazon SES](https://aws.amazon.com/ses/) handles interacting with other mail servers to deliver and receive your emails.
For outgoing mail, this is enabled by simply configuring SES as a relay host in Postfix.
Getting incoming mail from AWS to Dovecot is a more complicated process, requiring an additional Docker container acting as an abstraction layer between the two.

### Sending mail
Alpine-based Postfix Docker image [coreybraun/postfix-ses-relay](https://hub.docker.com/r/coreybraun/postfix-ses-relay) is used as your email client's SMTP server. This container uses [Dovecot SASL](https://doc.dovecot.org/configuration_manual/howto/postfix_and_dovecot_sasl/) over docker networking to authenticate SMTP clients with the same credentials they use for IMAP.

After a client authenticates and submits a message, Postfix decides whether the client is allowed to use the address specified in the 'From' field. This decision is made by looking up the address in the [Postfix lookup table](https://www.postfix.org/DATABASE_README.html) indicated in environment variable `POSTFIX_LOOKUP_TABLE` (which is configured as a [sender login map](https://www.postfix.org/postconf.5.html#smtpd_sender_login_maps) in Postfix). Assuming this lookup returns the same username the client authenticated with, Postfix proceeds to sending the message.

Postfix is configured to use Amazon SES as a relayhost for all outgoing messages. The [SES endpoint](https://docs.aws.amazon.com/general/latest/gr/ses.html) and [SMTP credentials](https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html#smtp-credentials-convert) used are derived from environment variables `AWS_REGION` and `AWS_IAM_CREDENTIALS`, respectively.

### Receiving mail
When Amazon SES receives an email for your domain(s), the recipient address is matched against a [set of receipt rules](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-receipt-rules-console-walkthrough.html). Upon matching a receipt rule, one or more [actions](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action.html) can be triggered.

While the end goal is to deliver email messages to our local IMAP server, Docker container [dovecot/dovecot](https://hub.docker.com/r/dovecot/dovecot), this is not immediately possible with SES receipt actions. Instead, we initially [deliver the email to an S3 bucket](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action-s3.html), where its raw content is stored as an object. Additionally, a notification is published to an [SNS topic](https://docs.aws.amazon.com/sns/latest/dg/welcome.html) for each S3 email delivery.

This is where our final Docker container, [coreybraun/ses-to-lmtp](https://hub.docker.com/r/coreybraun/ses-to-lmtp), comes in. This purpose-built containerized Python application takes emails from S3 and delivers them to the correct local user(s) in Dovecot via [LMTP](https://en.wikipedia.org/wiki/Local_Mail_Transfer_Protocol).

To trigger this process for each email, the container acts as an [SNS HTTPS endpoint](https://docs.aws.amazon.com/sns/latest/dg/sns-http-https-endpoint-as-subscriber.html) subscribed to the aforementioned SNS topic. This functionality is implemented using Python's [http.server](https://docs.python.org/3/library/http.server.html) and [ssl](https://docs.python.org/3/library/ssl.html) modules, alongside a custom request handler subclassed from [http.server's BaseHTTPRequestHandler](https://docs.python.org/3/library/http.server.html#http.server.BaseHTTPRequestHandler). This custom request handler additionally implements [HTTP basic auth](https://en.wikipedia.org/wiki/Basic_access_authentication), which, alongside [TLS](https://en.wikipedia.org/wiki/Transport_Layer_Security), secures the endpoint from unauthorized clients.

Another class, `S3MailProcessor`, uses method `process_notification_message` to handle each mail delivery notification message. This method does the following:
1. Parse the SNS notification for key information (bucket name, object key, recipient address list)
2. Get the raw email message from S3 using the AWS SDK for Python, [Boto3](https://boto3.amazonaws.com/v1/documentation/api/latest/index.html)
3. Convert the email from bytes to an [EmailMessage](https://docs.python.org/3/library/email.message.html#email.message.EmailMessage) object
4. Translate recipient email addresses to local usernames with [Postfix's postmap utility](https://www.postfix.org/postmap.1.html) (invoked with [subprocess.run](https://docs.python.org/3/library/subprocess.html); Queries the same lookup table used for [outgoing mail](#sending-mail))
5. Use [smtplib.LMTP](https://docs.python.org/3/library/smtplib.html#smtplib.LMTP) to deliver the email message to Dovecot

#### Retrying failed notification deliveries
If SNS fails to deliver a new mail notification to your HTTPS endpoint (due to network issues, container downtime, or an error handling the associated email, for example), delivery is retried twice: once after a minute, then again after an hour. Assuming these retry attempts also fail, the message is sent to an SQS dead letter queue.

A separate [thread](https://docs.python.org/3/library/threading.html) in the container is responsible for checking this dead letter queue and processing any notifications in it. It handles each notification in the queue using the same `process_notification_message` method described above. If the related email is processed successfully, the notification is deleted from the queue, otherwise it is left to be retried later.

The dead letter queue is checked once at container startup, then periodically at an interval (in seconds) set by environment variable `DEAD_LETTER_QUEUE_CHECK_INTERVAL` (default `21600` - 6 hours).

## Requirements
To deploy this solution, you will need the following:
- An AWS account
- A domain name which you can edit DNS records for
- A Linux server, which
  - has [Docker and Docker Compose](https://docs.docker.com/engine/install/) installed
  - has an A/AAAA DNS record pointing to it
  - has an SSL cert, signed by a trusted CA, for this DNS entry
  - you have the ability to open ports on
- A place to store user mailboxes, either
  - A directory in a locally-mounted filesystem on your Linux server
  - An NFS share mountable by your Linux server

Besides these requirements, some level of familiarity with Linux, Docker, and AWS is expected.
Relevant documentation and informational resources are linked throughout this README for those who wish to learn more.

If you need a domain name, I can recommend [Porkbun](https://porkbun.com/) as a registrar. I have several domains registered through Porkbun, and have had a good experience registering/renewing with them as well as using their nameservers.

If you need an SSL cert, you may want to look into [Let's Encrypt](https://letsencrypt.org/) for a free cert, along with an [ACME client](https://letsencrypt.org/docs/client-options/), such as [Certbot](https://certbot.eff.org/), for automated renewals.

Your method of opening ports will depend on how your Linux server is hosted.

If your server is a VPS, you'll need to look into your provider's method of opening ports.

If you're hosting the server yourself in a typical network, you will need to allow public access to each port from your firewall/router. If using IPv4, you will also typically need to create inbound NAT mappings (aka [port forwards](https://en.wikipedia.org/wiki/Port_forwarding)) on your router which point to your Linux server's private IP.

## Deployment
To use this email server, you will need to deploy Docker containers using [Docker Compose](https://docs.docker.com/compose/), as well as AWS resources using [AWS CloudFormation](https://aws.amazon.com/cloudformation/).

For convenience, pre-built docker images from this repository are publicly available on [Docker Hub](https://hub.docker.com/):
- [coreybraun/ses-to-lmtp](https://hub.docker.com/r/coreybraun/ses-to-lmtp)
- [coreybraun/postfix-ses-relay](https://hub.docker.com/r/coreybraun/postfix-ses-relay)

This repository's CloudFormation template is also publicly available in S3 for easy deployment:
- [main.yaml](https://corey-braun-cloudformation.s3.amazonaws.com/hybrid-cloud-email/v2/main.yaml)

Note: Only CloudFormation template(s) from the most recent [GitHub release](https://github.com/corey-braun/hybrid-cloud-email/releases) of each major version are hosted in S3.
To deploy a newer/older version of a template, you must upload the template file manually.

The following sub-sections will assume you are using the templates/images linked above. Advanced users may choose to manually build Docker images or upload CloudFormation templates from this repository, but these instructions will not cover doing so.

It is strongly recommended to deploy your `ses-to-lmtp` container and ensure its HTTPS endpoint is reachable from the internet before deploying AWS resources. If an SNS subscription is created for your endpoint while it is unavailable, the subscription message will fail to be delivered, and you will have to manually retry sending it later.

### Docker
This section will walk through the process of deploying this solution's Docker containers using Docker Compose. Before starting, ensure the Linux server you are using meets the criteria in the [Requirements section](#requirements). All commands listed here should be run as root.

Using a [.env file](https://docs.docker.com/compose/environment-variables/set-environment-variables/#substitute-with-an-env-file) for environment variable substitution, along with [Docker secrets](https://docs.docker.com/compose/use-secrets/), most configuration can be done without editing the repository's `docker-compose.yml` file. This section will cover configuration primarily using these methods, as separating your config from `docker-compose.yml` makes updating to a newer version of the repository easier.

First, clone the repository, cd into it, and copy `.env.example` to `.env`:
```
git clone https://github.com/corey-braun/hybrid-cloud-email
cd hybrid-cloud-email
cp .env.example .env
```

From here you can edit `.env` as you choose. The comments in this file provide further information on what each variable does. Commented variable definitions (those prefixed with a single `#` and no space) depend on outputs from CloudFormation, and can be left commented until you deploy your AWS resources.

Once you're done configuring your environment variables, you can pull the required container images from Docker Hub:
```
docker compose pull
```

Next, create your Docker secret files for passing sensitive information to your containers.
Assuming you're using the default `SECRETS_PATH` of `./secrets`, use the following commands to create your secrets folder and files, as well as apply appropriate permissions to each:
```
mkdir secrets
cd secrets
touch dovecot_passwd sns_basic_auth_credentials aws_iam_credentials postfix_lookup_table
chmod -R go-rwx .
chown 101 dovecot_passwd
cd ..
```

`dovecot_passwd` is a [Dovecot passwd-file](https://doc.dovecot.org/configuration_manual/authentication/passwd_file/#authentication-passwd-file) used to authenticate user email clients when they connect to Dovecot or Postfix.
It is used by Dovecot as a [userdb](https://doc.dovecot.org/configuration_manual/authentication/user_databases_userdb/) and [passdb](https://doc.dovecot.org/configuration_manual/authentication/password_databases_passdb/).
Each line in this file should be formatted as follows:
```
username:{SCHEME}hashed_password::
```

To generate this password hash, you can use dovecot's `doveadm pw` utility in a temporary container:
```
docker run --rm -it dovecot/dovecot doveadm pw
```

`sns_basic_auth_credentials` contains the basic auth credentials AWS will provide when delivering notifications to your SNS HTTPS endpoint.
The contents of this file should be in the following format:
```
username:password
```

`aws_iam_credentials` is used by container `ses-to-lmtp` to interact with SQS and S3 using Boto3, and by `postfix-ses-relay` to generate SMTP credentials used to send mail via SES.
The contents of this file should be in the following format:
```
access_key:secret_access_key
```

Instructions on generating your access key and secret access key will be covered in the following [AWS](#aws) section. For now, you can leave this file empty.

`postfix_lookup_table` should be a [Postfix Lookup Table](https://www.postfix.org/DATABASE_README.html) which translates email addresses to local account usernames contained in secret `dovecot_passwd`.
This lookup table will be used by `postfix-ses-relay` to decide whether a user is allowed to use the 'From' address specified in outgoing emails.
It is also used by `ses-to-lmtp` to translate recipient addresses into local account usernames for delivery via LMTP.

It is recommended to use a [PCRE (Perl Compatible Regular Expression)](https://www.postfix.org/pcre_table.5.html) lookup table. If using a different lookup table type, you must change the value of environment variable `POSTFIX_LOOKUP_TABLE` for containers `ses-to-lmtp` and `postfix-ses-relay`.

The following is an example of what the contents of a PCRE lookup table might be for a setup with local users `adam`, `jack`, and `ryan`, and domains `example.com` and `my.fqdn`:
```
/^(adam|jack)(\+[^@]*)?@(example\.com|my\.fqdn)$/   ${1}
/^[^@]*@example\.com$/   ryan
```

The lines/statements in the above PCRE Postfix lookup table do the following:
1. Allow users `adam` and `jack` to send/receive emails from/to their usernames, along with an optional plus extension, at domains `example.com` and `my.fqdn`
2. Allow user `ryan` to send/receive emails from/to any addresses not belonging to adam or jack at domain `example.com`

Here are some example lookup results from this table:
| Query       | Result      | Statement Matched |
| ----------- | ----------- | ----------------- |
| adam@example.com | adam | First |
| jack+abc@my.fqdn | jack | First |
| ryan@example.com | ryan | Second |
| xyz@example.com | ryan | Second |
| ryan@my.fqdn | None | None |

When creating your own lookup table, you can use Postfix's [postmap](https://www.postfix.org/postmap.1.html) utility for testing, which writes the result of your query to stdout:
```
postmap -q <query> <table_type>:<table_path>
```

Once you've finished configuring your `.env` and secret files, you are ready to start your containers for the first time.
`postfix-ses-relay` requires IAM credentials to run, so for now we will only start the other two containers:
```
docker compose up -d dovecot ses-to-lmtp
```

To view the logs of your containers, you can run `docker logs <container_name>`. Adding the `-f` flag will follow the logs of the container, allowing you to watch them in real time.

Once you've finished deploying your AWS resources and configuring any remaining environment variables/secrets, you can (re)start all of your containers:
```
docker compose up -d --force-recreate
```

### AWS
This section will walk through the process of deploying this solution's AWS resources using [CloudFormation](https://aws.amazon.com/cloudformation/) from the [AWS Web Management Console](https://docs.aws.amazon.com/awsconsolehelpdocs/latest/gsg/learn-whats-new.html).

Before starting, be sure your SNS HTTPS endpoint on Docker container `ses-to-lmtp` is accessible from the internet. If it is not reachable by AWS, the SNS subscription message will not be received.

To get started, click the "Launch on AWS" button below.

[![Launch on AWS](https://docs.aws.amazon.com/images/AmazonCloudFront/latest/DeveloperGuide/images/launch-on-aws-button.png)](https://console.aws.amazon.com/cloudformation/home#/stacks/new?stackName=HybridCloudEmail&templateURL=https://corey-braun-cloudformation.s3.amazonaws.com/hybrid-cloud-email/v2/main.yaml)

Be sure you have a [region SES supports email receiving in](https://docs.aws.amazon.com/ses/latest/dg/regions.html#region-receive-email) selected. In the web console, you can check/change your region from the right side of the top navigation bar, just left of your account's username.

All you have to do in the first page/step is specify a CloudFormation template to use. The S3 URL should already be filled in, so you can click the `Next` button to move on.

On the second step, you'll configure the parameters CloudFormation uses when deploying this template. Each parameter's description briefly explains what it does and links to more information.

Parameter `RecipientConditions` limits which recipient addresses SES will accept incoming email for.
You must ensure any recipient addresses SES accepts evaluate to local usernames in the Postfix Lookup Table you created in the [Docker](#docker) section.
For instance, if you were using the example lookup table from that section, you would set this parameter to `adam@my.fqdn,jack@my.fqdn,example.com`.
See [this AWS documentation](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-receipt-rules-console-walkthrough.html#receipt-rules-create-rule-settings) for more information on recipient conditions.

On the third step you can configure stack deployment options. Each option here is already populated with a suitable default, so you can just click `Next` to move on.

The fourth and final step asks you to review your deployment. At the bottom of this page you will have to confirm three checkboxes acknowledging that the template requires the additional capability `CAPABILITY_AUTO_EXPAND`. This capability is required to use the [AWS::LanguageExtensions transform](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/transform-aws-languageextensions.html), which [scales the template's created resources and outputs](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/intrinsic-function-reference-foreach.html) based on how many domains you specify in parameter `MailDomains`. Once you have checked these boxes, you can click "Submit" to start deploying your AWS resources

Once your stack finishes deploying, there are a few manual steps you must take.

From your stack overview, click the "Resources" tab. From here, click the link under the `Physical ID` section for resource `SesReceiptRuleSet`. On this page, you will need to click the `Set as active` button in the top right. Since only one receipt rule set can be active on your account in each region, this cannot be done automatically with CloudFormation.

Back at your stack resources, click the `Physical ID` link for resource `IamMailUser`. On this page, click `Security credentials`, then `Create access key`. Select use case "Application running outside AWS", then click `Next`. Set a description tag if you'd like, then click `Create access key`. Write the "Access key" and "Secret access key" generated here to Docker secret file `aws_iam_credentials` in the format:
```
access_key:secret_access_key
```

Again from your stack resources, find the `SqsNewMailDeadLetterQueue` resource. The contents of this resource's `Physical ID` should be set as the value of Docker environment variable `DEAD_LETTER_QUEUE_URL` for container `ses-to-lmtp`.

Returning to your stack overview, click the "Outputs" tab this time. For each domain you provided in parameter `MailDomains`, there should be 4 output keys containing "DnsRecord" (or 6, if parameter `MailFromSubDomain` was non-empty). For each of these outputs, you will need to create the DNS record in the "Value" column.

Each "DnsRecord" output's value contains a DNS record formatted as follows:
```
[sub.]domain.tld TYPE Answer
```

With some DNS providers, the number at the start of each MX record's answer may need to be entered in a separate "Priority" field, rather than included in the answer section.

If you wish to create these DNS records programmatically (by using your nameservers' API, for example), you can use the following [AWS CLI](https://aws.amazon.com/cli/) command to get the value of every "DnsRecord" output as a JSON-formatted list:
```
aws cloudformation describe-stacks --stack-name HybridCloudEmail --query "Stacks[0].Outputs[?contains(OutputKey,'DnsRecord')].OutputValue"
```

After creating these DNS records, you can check to see if AWS has successfully verified your domain identities [here](https://console.aws.amazon.com/ses/home#/verified-identities).
Keep in mind that it will take time for your DNS records to propagate and be checked by AWS.

### Moving out of the SES sandbox
Upon initial deployment, your account will still be in the Amazon SES sandbox.
Until you manually request production access to SES, [certain restrictions](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html) will be imposed on your usage of SES, most notably:
> - You can only send mail to verified email addresses and domains, or to [the Amazon SES mailbox simulator](https://docs.aws.amazon.com/ses/latest/dg/send-an-email-from-console.html#send-email-simulator).

Once you've finished deploying, configuring, and testing this solution, you will likely want to request production access to SES. [To do so from the AWS Management Console, visit this page](https://console.aws.amazon.com/ses/home#/get-set-up).

After following the link above, make sure you have the correct AWS region selected (the same one you deployed your resources in with CloudFormation).

From here, you should be able to click the `Request production access` button, after which you'll have to fill out a form explaining how you plan to use SES. This can be somewhat awkward since the form asks questions intended for businesses sending bulk marketing/transactional emails, so just do your best to explain your use case of sending/receiving personal email.

After filling out the form, you may receive a response starting like this:
> Hello,
>
> Thank you for submitting your request to increase your sending limits. We would like to gather more information about your use case.

This is most likely because your response didn't satisfy an automated keyword search. If do receive such a message, try to reply with any additional information requested.

After requesting production access, you should receive a response within 24 hours, hopefully telling you that your account has been moved out of the SES sandbox.

## Pricing
This section goes over the AWS resources deployed with this solution which Amazon may bill you for.

In this solution, billable resources are deployed from 4 different AWS categories. Linked below are the pricing pages for each:
- [Amazon Simple Email Service (SES)](https://aws.amazon.com/ses/pricing/)
- [Amazon Simple Notification Service (SNS)](https://aws.amazon.com/sns/pricing/)
- [Amazon Simple Queue Service (SQS)](https://aws.amazon.com/sqs/pricing/)
- [Amazon S3](https://aws.amazon.com/s3/pricing/)

This section was last updated 12/24/2023.
Since AWS's pricing and billing policies may change in the future, you should verify any billing information stated here for yourself.
You alone are liable for the cost of any AWS resources you use; Be sure to consult the pages linked above for complete and up-to-date pricing information.

### SES
With SES, you are charged per email you send or receive, each counting as one message charge.

You are additionally charged for the amount of data sent/received in messages.
The size of each message includes headers, content, and attachments.
Rates for sent and received data are different.

Sending an email to multiple recipients (To/CC/BCC) incurs costs for every recipient.
For example, sending an email to 10 recipients will incur 10 message charges and 10 outgoing data charges.

This table shows SES's rates at the time of writing:
| Charge Type | Unit | Price |
| --- | --- | --- |
| Message charge | 1000 | $0.10 |
| Incoming data | 1GB | $0.36 |
| Outgoing data | 1GB | $0.12 |

SES's free tier is available for your first 12 months using it, during which your first 3000 message charges per month are free.
You will still be charged for all incoming/outgoing data in these messages.

SES charges will most likely make up the majority of costs incurred using this setup.

### SNS
Each time an email matching your receipt rules is received by SNS, a notification is posted to an SNS topic.
This notification is then delivered to your HTTPS endpoint on docker container `ses-to-lmtp`.

1,000,000 messages can be posted to SNS topics for free per month. Therefore, this charge will be zero for most users.

Delivering messages to an HTTPS endpoint costs $0.60 per 1,000,000 messages. With the free tier, your first 100,000 HTTPS endpoint message deliveries are free.
After the free tier, this cost will likely remain near-zero for most users due to the low price per message.

Data transfer out of SNS costs $0.09 per GB. Since only email headers and delivery data are included in each SNS notification, this charge will be near-zero for most users.

### SQS
If SNS notification delivery to your HTTPS endpoint fails, the message is place into an SQS queue.

Every time a message is added to the queue, or container `ses-to-lmtp` polls for messages in the queue, it is counted as an SQS API request. 1,000,000 requests per month are included in the SQS free tier, so this charge will be zero for most users.

Data transfer out of SQS costs $0.09 per GB. Use of SQS is infrequent, so this cost will be near-zero for most users.

### S3
Email files are stored in an S3 bucket after being received by SES.
As soon as Docker container `ses-to-lmtp` receives the SNS/SQS notification for an email's delivery, its contents are pulled from S3.
Assuming the email is successfully delivered to Dovecot via LMTP, it is then deleted from S3.

The first 100GB of data transferred out of S3 per month is free.
Therefore, this charge will be zero for most users.

Storing data in S3 costs $0.023 per GB, per month.
Since email files are deleted soon after being put in S3, this charge will be near-zero.
