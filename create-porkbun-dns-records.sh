#!/usr/bin/env bash
## Creates Porkbun DNS records from CloudFormation outputs
## https://github.com/corey-braun/hybrid-cloud-email

## Requires jq: https://jqlang.github.io/jq/
## Requires AWS CLI: https://aws.amazon.com/cli/
## Requires corey-braun/porkbun-api-bash: https://github.com/corey-braun/porkbun-api-bash

CLOUDFORMATION_STACK='HybridCloudEmail'

log_exit() {
    echo "Error: $1" >&2
    exit 1
}

## Parse DNS record string and set the following variables: domain type answer subdomain priority
parse_dns_record() {
    read domain type answer <<< "$1"

    ## Separate subdomain from domain
    subdomain="${domain%.*.*}"
    if [ "$subdomain" = "$domain" ]; then
        unset subdomain
    else
        domain="${domain#$subdomain.}"
    fi

    ## Separate MX record priority from answer
    if [ "$type" = MX ]; then
        read priority answer <<< "$answer"
    fi
}

create_dns_record() {
    local domain type answer subdomain priority
    parse_dns_record "$1"

    args=("type=$type" "content=$answer")
    [ -n "$subdomain" ] && args+=("name=$subdomain")
    [ -n "$priority" ] && args+=("prio=$priority")

    echo "Creating DNS record '$1'"
    porkbun-api custom "dns/create/$domain" "${args[@]}"
    echo
}

delete_dns_record() {
    local domain type answer subdomain priority
    parse_dns_record "$1"

    echo "Deleting DNS record '$1'"
    porkbun-api custom "dns/deleteByNameType/$domain/$type/$subdomain"
    echo
}

## Get DNS records as an array from CloudFormation outputs
mapfile -t DNS_RECORDS < <(aws cloudformation describe-stacks --stack-name "$CLOUDFORMATION_STACK" --query "Stacks[0].Outputs[?contains(OutputKey,'DnsRecord')].OutputValue" | jq -r .[])
[ "$?" -ne 0 ] && log_exit 'Error getting DNS records from CloudFormation stack outputs'

## Create (or delete) each DNS record
if [ "$1" = 'delete' ]; then
    for record in "${DNS_RECORDS[@]}"; do
        delete_dns_record "$record"
    done
else
    for record in "${DNS_RECORDS[@]}"; do
        create_dns_record "$record"
    done
fi
