#!/usr/bin/env bash
set -e

# Usage:
#  VIRTHOST=my.big.hypervisor.net
#  ./infrared-openstack.sh

VIRTHOST=${VIRTHOST:-localhost}
AMQP_HOST=${AMQP_HOST:-default-interconnect-5671-service-telemetry.apps-crc.testing}
AMQP_PORT=${AMQP_PORT:-443}
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
NTP_SERVER="${NTP_SERVER:-clock.redhat.com,10.5.27.10,10.11.160.238}"
CLOUD_NAME="${CLOUD_NAME:-sample}"

VM_IMAGE_URL_PATH="${VM_IMAGE_URL_PATH:-http://download.devel.redhat.com/rhel-7/rel-eng/RHEL-7/latest-RHEL-7.9/compose/Server/x86_64/images}"
# Recommend these default to tested immutable dentifiers where possible, pass "latest" style ids via environment if you want them
VM_IMAGE="${VM_IMAGE:-rhel-guest-image-7.9-30.x86_64.qcow2}"
VM_IMAGE_LOCATION="${VM_IMAGE_URL_PATH}/${VM_IMAGE}"

OSP_BUILD="${OSP_BUILD:-7.9-passed_phase2}"
OSP_VERSION="${OSP_VERSION:-13}"
OSP_TOPOLOGY="${OSP_TOPOLOGY:-undercloud:1,controller:3,compute:2,ceph:3}"
OSP_MIRROR="${OSP_MIRROR:-rdu2}"
OSP_REGISTRY_MIRROR="${OSP_REGISTRY_MIRROR:-registry-proxy.engineering.redhat.com}"
LIBVIRT_DISKPOOL="${LIBVIRT_DISKPOOL:-/var/lib/libvirt/images}"
ENVIRONMENT_TEMPLATE="${ENVIRONMENT_TEMPLATE:-stf-connectors.yaml.template}"
ENABLE_STF_ENVIRONMENT_TEMPLATE="${ENABLE_STF_ENVIRONMENT_TEMPLATE:-enable-stf.yaml.template}"
OVERCLOUD_DOMAIN="${OVERCLOUD_DOMAIN:-`hostname -s`}"
CA_CERT_FILE_CONTENT="${CA_CERT_FILE_CONTENT:-}"
TEMPEST_ONLY="${TEMPEST_ONLY:-false}"
ENABLE_STF_CONNECTORS="${ENABLE_STF_CONNECTORS:-true}"

ir_run_cleanup() {
  infrared virsh \
      -vv \
      -o outputs/cleanup.yml \
      --disk-pool "${LIBVIRT_DISKPOOL}" \
      --host-address "${VIRTHOST}" \
      --host-key "${SSH_KEY}" \
      --cleanup yes
}

ir_run_provision() {
  infrared virsh \
      -vvv \
      -o outputs/provision.yml \
      --disk-pool "${LIBVIRT_DISKPOOL}" \
      --topology-nodes "${OSP_TOPOLOGY}" \
      --host-address "${VIRTHOST}" \
      --host-key "${SSH_KEY}" \
      --image-url "${VM_IMAGE_LOCATION}" \
      --host-memory-overcommit True \
      -e override.controller.cpu=4 \
      -e override.controller.memory=16384 \
      --serial-files True
}

ir_create_undercloud() {
  infrared tripleo-undercloud \
      -vv \
      -o outputs/undercloud-install.yml \
      --mirror "${OSP_MIRROR}" \
      --version "${OSP_VERSION}" \
      --build "${OSP_BUILD}" \
      --images-task rpm \
      --images-update no \
      --registry-mirror "${OSP_REGISTRY_MIRROR}" \
      --tls-ca https://password.corp.redhat.com/RH-IT-Root-CA.crt \
      --overcloud-domain "${OVERCLOUD_DOMAIN}" \
      --config-options DEFAULT.undercloud_timezone=UTC \
      --config-options DEFAULT.container_insecure_registries="${OSP_REGISTRY_MIRROR}"
}

ir_image_sync_undercloud() {
  infrared tripleo-undercloud \
      -o outputs/undercloud-image-sync.yml \
      --images-task rpm \
      --build "${OSP_BUILD}" \
      --mirror "${OSP_REGISTRY_MIRROR}" \
      --images-update no
}

stf_create_config() {
  sed -r "s/<<AMQP_HOST>>/${AMQP_HOST}/;s/<<AMQP_PORT>>/${AMQP_PORT}/;s/<<CLOUD_NAME>>/${CLOUD_NAME}/;s%<<CA_CERT_FILE_CONTENT>>%${CA_CERT_FILE_CONTENT//$'\n'/<@@@>}%;s/<@@@>/\n                /g" ${ENVIRONMENT_TEMPLATE} > outputs/stf-connectors.yaml
}

enable_stf_create_config() {
  cat ${ENABLE_STF_ENVIRONMENT_TEMPLATE} > outputs/enable-stf.yaml
}

ir_create_overcloud() {
  infrared tripleo-overcloud \
      -vv \
      -o outputs/overcloud-install.yml \
      --version "${OSP_VERSION}" \
      --deployment-files virt \
      --overcloud-debug yes \
      --network-backend vlan \
      --network-protocol ipv4 \
      --storage-backend ceph \
      --storage-external no \
      --overcloud-ssl no \
      --introspect yes \
      --tagging yes \
      --deploy yes \
      --ntp-server "${NTP_SERVER}" \
      --overcloud-templates ceilometer-write-qdr-edge-only,outputs/enable-stf.yaml,outputs/stf-connectors.yaml \
      --overcloud-domain "${OVERCLOUD_DOMAIN}" \
      --containers yes
}

ir_run_tempest() {
  infrared tempest \
      -vv \
      -o outputs/test.yml \
      --openstack-installer tripleo \
      --openstack-version "${OSP_VERSION}" \
      --tests smoke \
      --setup rpm \
      --revision=HEAD \
      --image http://download.cirros-cloud.net/0.4.0/cirros-0.4.0-x86_64-disk.img
}

if [ -z "${CA_CERT_FILE_CONTENT}" ]; then
    echo "CA_CERT_FILE_CONTENT must be set and passed to the deployment, or QDR will fail to connect."
    exit 1
fi

if ${TEMPEST_ONLY}; then
  echo "-- Running tempest tests"
  ir_run_tempest
else
  echo "-- full cloud deployment"
  echo ">> Cloud name: ${CLOUD_NAME}"
  echo ">> Overcloud domain: ${OVERCLOUD_DOMAIN}"
  echo ">> STF enabled: ${ENABLE_STF_CONNECTORS}"
  echo ">> OSP version: ${OSP_VERSION}"
  echo ">> OSP build: ${OSP_BUILD}"
  echo ">> OSP topology: ${OSP_TOPOLOGY}"

  ir_run_cleanup
  ir_run_provision
  ir_create_undercloud
  ir_image_sync_undercloud
  if ${ENABLE_STF_CONNECTORS}; then
    stf_create_config
    enable_stf_create_config
  else
    touch outputs/stf-connectors.yaml
    truncate --size 0 outputs/stf-connectors.yaml
    touch outputs/enable-stf.yaml
    truncate --size 0 outputs/enable-stf.yaml
  fi
  ir_create_overcloud

  echo "-- deployment completed"
  echo ">> Cloud name: ${CLOUD_NAME}"
  echo ">> Overcloud domain: ${OVERCLOUD_DOMAIN}"
  echo ">> STF enabled: ${ENABLE_STF_CONNECTORS}"
  echo ">> OSP version: ${OSP_VERSION}"
  echo ">> OSP build: ${OSP_BUILD}"
  echo ">> OSP topology: ${OSP_TOPOLOGY}"
fi
# vim: set shiftwidth=4 tabstop=4 expandtab:
