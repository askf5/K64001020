#!/bin/bash

#####################################
# Date: Fri Sep 16 11:45:19 EDT 2022
# Version: 1.5

days="3650"

update_controllers=0
if [[ "$1" != "" ]]; then
    if [[ "$1" == "-controllers" ]]; then
        update_controllers=1
    else 
        echo ""
        echo "ERROR: invalid option \"$1\""
        echo "    USAGE $0 [-controllers]"
        echo ""    
        exit -1
    fi    
fi

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
# Pause orchestration-manager processing while script is running
###############################################################

ssh controller-1.chassis.local touch /tmp/omd/pause
ssh controller-2.chassis.local touch /tmp/omd/pause

###############################################################
# Approve any outstanding CSR's before updating anything
###############################################################

outstandingCerts=$(oc get csr | grep Pending)

if [[ "$outstandingCerts" != "" ]]; then 
    echo "=================================================================="
    echo "Approving any outstand CSR Requests"
    oc get csr | grep -E Pending | awk '{print $1}' | xargs oc adm certificate approve
fi

if [[ $update_controllers == 1 ]]; then
    ###############################################################
    # Make sure etc_ansible_hosts file exists on this CC
    ###############################################################

    blades=$(oc get nodes | grep blade |awk '{print $1}')

    if [[ ! -f /tmp/omd/etc_ansible_hosts ]]; then
        if [[ $(hostname) == "controller-1.chassis.local" ]]; then
            echo "/tmp/omd/etc_ansible_hosts does not exist, copy from controller-2.chassis.local"    
            scp controller-2.chassis.local://tmp/omd/etc_ansible_hosts /tmp/omd/etc_ansible_hosts
        else 
            echo "/tmp/omd/etc_ansible_hosts does not exist, copy from controller-1.chassis.local"    
            scp controller-1.chassis.local://tmp/omd/etc_ansible_hosts /tmp/omd/etc_ansible_hosts
        fi    
    else 
        echo "/tmp/omd/etc_ansible_hosts exists"    
    fi

    ###############################################################
    # If specified, redeploy the controller certs and create a new CA
    ###############################################################

    time docker exec -it orchestration_manager ansible-playbook -i /tmp/omd/etc_ansible_hosts /usr/share/ansible/openshift-ansible/playbooks/openshift-master/redeploy-certificates.yml -e openshift_hosted_registry_cert_expire_days=${days} -e openshift_ca_cert_expire_days=${days} -e openshift_master_cert_expire_days=${days} -e etcd_ca_default_days=${days} -e expire_days=${days} -e expire_days=${days} -e openshift_certificate_expiry_fail_on_warn=false -e openshift_redeploy_openshift_ca=true

    time docker exec -it orchestration_manager ansible-playbook -i /tmp/omd/etc_ansible_hosts /usr/share/ansible/openshift-ansible/playbooks/redeploy-certificates.yml -e openshift_hosted_registry_cert_expire_days=${days} -e openshift_ca_cert_expire_days=${days} -e openshift_master_cert_expire_days=${days} -e etcd_ca_default_days=${days} -e expire_days=${days} -e expire_days=${days} -e openshift_certificate_expiry_fail_on_warn=false -e openshift_redeploy_openshift_ca=true

    ###############################################################
    # Update the ca certs in the kubeconfig files
    ###############################################################

    oc serviceaccounts create-kubeconfig node-bootstrapper -n openshift-infra --config /etc/origin/master/admin.kubeconfig > /tmp/omd/bootstrap.kubeconfig

    ssh controller-1.chassis.local cp /etc/origin/master/admin.kubeconfig /etc/origin/node/bootstrap.kubeconfig
    ssh controller-2.chassis.local cp /etc/origin/master/admin.kubeconfig /etc/origin/node/bootstrap.kubeconfig

    for node in $blades; do
        scp /tmp/omd/bootstrap.kubeconfig /etc/origin/node/bootstrap.kubeconfig
    done

    scp  /tmp/omd/bootstrap.kubeconfig controller-1.chassis.local:/etc/origin/master/bootstrap.kubeconfig   
    scp  /tmp/omd/bootstrap.kubeconfig controller-2.chassis.local:/etc/origin/master/bootstrap.kubeconfig   
fi

###############################################################
# Update the node kubelet certs
###############################################################


for node in $(oc get nodes |awk 'NR>1'|awk '{print $1}'); do
    echo "=================================================================="
    echo "Renew Cert on node: $node"
    echo "=================================================================="

    echo "   Remove /etc/origin/node/certificates/kubelet-server-current.pem"
    ssh "${node}" rm -f /etc/origin/node/certificates/kubelet-server-current.pem
    echo "   Remove /etc/origin/node/certificates/kubelet-client-current.pem"
    ssh "${node}" rm -f /etc/origin/node/certificates/kubelet-client-current.pem

    if [[ $update_controllers == 1 ]]; then
        echo "   Move client-ca"
        ssh "${node}" mv /etc/origin/node/client-ca.crt{,.old}
        echo "   Move node.kubeconfig"
        ssh "${node}" mv /etc/origin/node/node.kubeconfig{,.old}
    fi
        
    echo "   Restart origin-node container"
    ssh "${node}" systemctl restart origin-node &
    
    ((exists=0))
    echo "   Approve outstanding CSR's for node $node ..."
    while [[ $exists != 2 ]]; do
       outstandingCerts=$(oc get csr | grep Pending)
       if [[ "$outstandingCerts" != "" ]]; then 
           oc get csr | grep -E Pending | awk '{print $1}' | xargs oc adm certificate approve
       fi

       ((exists=0))
       ssh "${node}" "ls -lq /etc/origin/node/certificates/kubelet-server-current.pem 2>&1" > /dev/null
       if [[ $? == 0 ]]; then ((exists=exists+1)); fi
       ssh "${node}" "ls -lq /etc/origin/node/certificates/kubelet-client-current.pem 2>&1" > /dev/null
       if [[ $? == 0 ]]; then ((exists=exists+1)); fi

       if [[ $exists != 2 ]]; then sleep 1; fi
    done

    # wait for the restart origin-node call to finish    
    wait
    
    sleep 10

    echo "   Wait for node $node to return to Ready ..."
    nodeReady=$(oc get nodes | grep -E "${node}" | awk '{print $2}')
    while [[ "$nodeReady" != "Ready" ]]; do
        sleep 1
        nodeReady=$(oc get nodes | grep -E "${node}" | awk '{print $2}')
    done
done    

echo "================================================================="

sleep 10

oc get nodes
while [[ $? != 0 ]]; do
  sleep 5
  oc get nodes
done  

###############################################################
# Make sure all k8s services have restarted correctly
###############################################################

echo "================================================================="

oc delete pods -n kube-service-catalog -l app=apiserver
oc delete pods -n kube-service-catalog -l app=controller-manager

(( x=1 ))
(( count=1 ))
while (( count != 0 )); do
    echo "================================================================="
    count=$(oc get pods --all-namespaces | grep -E "Pending|Crash|0/1" | grep -E -v "ExitCode|helper|partition-" | wc -l)

    x=$(( x + 1 ))

    if (( x % 40 == 0 )); then
        oc delete pods -n kube-service-catalog -l app=apiserver
        oc delete pods -n kube-service-catalog -l app=controller-manager
    fi

    oc get nodes
    if [[ $? != 0 ]]; then
        (( count=1 ))
    fi

    echo "================================================================="
    echo "Waiting for services to restart and stabilize"
    
    if (( count != 0 )); then
        oc get pods --all-namespaces | grep -E "Pending|Crash|0/1" | grep -E -v "ExitCode|helper|partition-"
        sleep 1 
    fi

    tmp=$(oc get pods | grep Error | grep deploy | awk '{print $1}')
    if [[ "$tmp" != "" ]]; then
        for podName in $tmp; do 
            oc delete pod "$podName"
        done  
    fi

    if [[ $x -gt 240 ]]; then
        break
    fi    
done   

###############################################################
# Un-Pause orchestration-manager processing
###############################################################

ssh controller-1.chassis.local rm /tmp/omd/pause
ssh controller-2.chassis.local rm /tmp/omd/pause

###############################################################
# Check cert expiration times after the update
###############################################################

goodCerts=0;
warnCerts=0;
expiredCerts=0;

warnDays=60
warnAge=$((60 * 60 * 24 * warnDays))
now=$(date +%s)

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
