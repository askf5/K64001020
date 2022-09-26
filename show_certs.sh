#!/bin/bash

#####################################
# Date: Fri Sep  9 09:44:49 EDT 2022
# Version: 1.4

goodCerts=0;
warnCerts=0;
expiredCerts=0;

warnDays=60
warnAge=$((60 * 60 * 24 * warnDays))
now=$(date +%s)

###############################################################
# Get validity data from the cert
###############################################################

function showCert() {
    openssl crl2pkcs7 -nocrl -certfile /dev/stdin | openssl pkcs7 -print_certs -text | grep Validity -A2
}

###############################################################
# Parse the cert date and determine the validity
###############################################################

function subDate {
    dateSeconds=$(date -d "$tmp" +%s)
    diff=$((dateSeconds - now))
    valid=$((diff/60/60/24))
    if ((diff<warnAge)); then
        if ((diff<=0)); then
            echo "$1EXPIRED: $f cert has already expired $valid days ago"
            expiredCerts=$(( expiredCerts + 1 ))
        else
            echo "$1WARNING: $f cert expires in $valid days"
            warnCerts=$(( warnCerts + 1 ))
        fi
    else
        echo "$1$f cert is valid for $valid more days"
        goodCerts=$(( goodCerts + 1 ))
    fi
}

###############################################################
# Process the cert date information
###############################################################

function processDate {
    tmp=$(echo "$dateInfo" | sed s/[\ A-Za-z]*After\ :[\ ]*// | cut -c -25)
    subDate "$1"
}

###############################################################
# Display controller cert validity
##############################################################

echo ""
echo "###############################################################"
echo "# Process all cert files under /etc/origin/master directory"
echo "###############################################################"
echo ""

for node in $(oc get nodes | grep -E controller | awk '{print $1}'); do
    echo "$node:"
    for f in $(ssh "$node" "find /etc/origin/master -type f \(  -name '*.crt' -o -name '*pem' \)"); do
        if [[ "$f" != /etc/origin/master/openshift-aggregator.crt ]]; then
            dateInfo=$(ssh "$node" cat "$f" | showCert | grep -E After | tail -1)
            processDate "    "
        fi
    done
done

###############################################################
# Display kubelet cert validity
###############################################################

echo ""
echo "###############################################################"
echo "# Process all node cert files /etc/origin/node"
echo "###############################################################"
echo ""

for node in $(oc get nodes |awk 'NR>1'|awk '{print $1}'); do
    echo "$node:"
    for f in $(ssh "$node" "find /etc/origin/node -type f \( -name '*.crt' \)"); do
        dateInfo=$(ssh "$node" cat "$f" | showCert | grep -E After | tail -1)
        processDate "    "
    done

    for f in $(ssh "$node" "find /etc/origin/node -name kubelet-*-current.pem"); do
        dateInfo=$(ssh "$node" cat "$f" | showCert | grep -E After | tail -1)
        processDate "    "
    done
done

###############################################################
###############################################################

echo ""
echo "###############################################################"
echo "Summary:"
echo "       Good Certs: $goodCerts"
echo "       Warn Certs: $warnCerts"
echo "    Expired Certs: $expiredCerts"
echo "###############################################################"
echo ""

if [[ $expiredCerts -gt 0 ]]; then
    exit -2
fi

if [[ $warnCerts -gt 0 ]]; then
    exit -1
fi

exit 0
