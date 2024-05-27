#!/usr/bin/env bash

# TODO make this script idempotent
function wait_for_pods() {
  local is_ready=1 # on shell 1 is false
  local max_iterations=20 # around 1 minute
  local iterations=0

until [[ "${is_ready}" -eq 0 ]] || [[ $iterations -eq $max_iterations ]]
do
  is_ready=0

  set +e
  echo "wait for hypershift pods to be Ready"
  pods=$(oc get pods -n hypershift --no-headers -o custom-columns=":metadata.name")
  for pod in ${pods}
   do status=$(oc get pod ${pod} -n hypershift --no-headers -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [[ ${status} != "True" ]]; then
        is_ready=1
    fi
  done
  set -e

  if [[ "${is_ready}" -eq 1 ]]; then
    iterations=$((iterations + 1))
    echo "waiting for hypershift pods to be ready"
    sleep 3
  fi
done
return "${is_ready}"
}

HOSTED_CLUSTER_NAME="${HOSTED_CLUSTER_NAME:=hostedcluster01}"
# The namespace on the management cluster on which the VMs used
# for the hosted cluster are reside.
VM_NS="${VM_NS:=mykubevirt}"
MANAGEMENT_CLUSTER_KUBECONFIG="${MANAGEMENT_CLUSTER_KUBECONFIG:=/root/ocp/auth/kubeconfig}"
NTO_CUSTOM_IMAGE="${NTO_CUSTOM_IMAGE:=quay.io/titzhak/origin-cluster-node-tuning-operator:support_pao_in_hypershift}"

# when provisioning the cluster using kcli, we should provide an extra kcli param - disconnected: false

# install ODF-LVM
kcli create app openshift lvms-operator
# install kubevirt client
kcli create app openshift kubevirt-hyperconverged
# enable the epel repo for installing python3-kubernetes
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
/usr/bin/crb enable
dnf install python3-kubernetes -y
kcli install provider kubevirt

# create hosted-cluster namespace
oc create ns "${HOSTED_CLUSTER_NS}"

make hypershift
./bin/hypershift install render > render.yaml
# deploy hypershift operator
oc create -f render.yaml

if ! wait_for_pods; then
  echo "hypershift pod is not ready. timeout exceeded"
  exit 1
fi

oc get pods -n hypershift -o wide

# append the following section in your ~/.kcli/config.yml:
cat <<EOF >> /root/.kcli/config.yml
default:
  client: mykubevirt
mykubevirt:
  type: kubevirt
  kubeconfig: "${MANAGEMENT_CLUSTER_KUBECONFIG}"
  namespace: "${HOSTED_CLUSTER_NS}"
  first_consumer: true"
EOF

# provide the hosted-cluster config for kcli
cat <<EOF > hypershift.yaml
cluster: "${HOSTED_CLUSTER_NAME}"
version: nightly
tag: 4.16
workers: 2
numcpus: 16
memory: 16384
disk_size: 80
platform: kubevirt
pull_secret: /root/openshift_pull.json
image_overrides: cluster-node-tuning-operator="${NTO_CUSTOM_IMAGE}"
storage:
  type: lvm
EOF

kcli create cluster hypershift --pf hypershift.yaml
# kcli delete --yes cluster $cluster

# hypershift operator watches for hosted cluster CR and creates the
# control plane on a hosted-ns on the mng cluster (control plane = api,etcd, etc.)
# ignition server - resposible for creating the workers of the hosted-cluster
# the hosted-cluster CR represents the control-plane
# node pool - represents the worker nodes
