#!/bin/bash
#
# Runs on the dev/CI machine to execute the test harness job in the cluster
#
# Requires:
#   * oc tools pointing at your STF instance
#   * gnu sed
#
# Usage: NUMCLOUDS=<num clouds> OCP_PROJECT=<project> ./smoketest.sh [NUMCLOUDS]
#
# NUMCLOUDS - how many clouds to simulate (that number of smart gateways and
# OCP_PROJECT - namespace you wish to use. Defaults to current
# collectd pods will be created)

# Generate an array of cloud names to use
NUMCLOUDS=${1:-1}
CLOUDNAMES=()

for ((i=1; i<=NUMCLOUDS; i++)); do
  NAME="smoke${i}"
  CLOUDNAMES+=(${NAME})
done
REL=$(dirname "$0")

if [ -n ${OCP_PROJECT+x} ]; then
    oc project $OCP_PROJECT 
fi


echo "*** [INFO] Getting ElasticSearch authentication password"
ELASTICSEARCH_AUTH_PASS=$(oc get secret elasticsearch-es-elastic-user -ogo-template='{{ .data.elastic | base64decode }}')

echo "*** [INFO] Creating configmaps..."
oc delete configmap/stf-smoketest-healthcheck-log configmap/stf-smoketest-collectd-config configmap/stf-smoketest-sensubility-config configmap/stf-smoketest-collectd-entrypoint-script configmap/stf-smoketest-ceilometer-publisher configmap/stf-smoketest-ceilometer-entrypoint-script job/stf-smoketest || true
oc create configmap stf-smoketest-healthcheck-log --from-file ${REL}/healthcheck.log
oc create configmap stf-smoketest-collectd-config --from-file ${REL}/minimal-collectd.conf.template
oc create configmap stf-smoketest-sensubility-config --from-file ${REL}/collectd-sensubility.conf
oc create configmap stf-smoketest-collectd-entrypoint-script --from-file ${REL}/smoketest_collectd_entrypoint.sh
oc create configmap stf-smoketest-ceilometer-publisher --from-file ${REL}/ceilometer_publish.py
oc create configmap stf-smoketest-ceilometer-entrypoint-script --from-file ${REL}/smoketest_ceilometer_entrypoint.sh

echo "*** [INFO] Creating smoketest jobs..."
oc delete job -l app=stf-smoketest
for NAME in "${CLOUDNAMES[@]}"; do
    oc create -f <(sed -e "s/<<CLOUDNAME>>/${NAME}/;s/<<ELASTICSEARCH_AUTH_PASS>>/${ELASTICSEARCH_AUTH_PASS}/" ${REL}/smoketest_job.yaml.template)
done

echo "*** [INFO] Triggering an alertmanager notification..."
oc run curl --restart='Never' --image=quay.io/infrawatch/busyboxplus:curl -- curl -H "Content-Type: application/json" -d '[{"labels":{"alertname":"Testalert1"}}]' http://alertmanager-operated:9093/api/v1/alerts
# it takes some time to get the alert delivered, continuing with other tests



# Trying to find a less brittle test than a timeout
JOB_TIMEOUT=300s
for NAME in "${CLOUDNAMES[@]}"; do
    echo "*** [INFO] Waiting on job/stf-smoketest-${NAME}..."
    oc wait --for=condition=complete --timeout=${JOB_TIMEOUT} "job/stf-smoketest-${NAME}"
    RET=$((RET || $?)) # Accumulate exit codes
done

oc delete pod curl
SNMP_WEBHOOK_POD=$(oc get pod -l "app=default-snmp-webhook" -ojsonpath='{.items[0].metadata.name}')
trapoutput=$(oc logs $SNMP_WEBHOOK_POD | grep 'Sending SNMP trap')
SNMP_WEBHOOK_STATUS=$?

echo "*** [INFO] Showing oc get all..."
oc get all
echo

echo "*** [INFO] Showing servicemonitors..."
oc get servicemonitor -o yaml
echo

echo "*** [INFO] Logs from smoketest containers..."
for NAME in "${CLOUDNAMES[@]}"; do
    oc logs "$(oc get pod -l "job-name=stf-smoketest-${NAME}" -o jsonpath='{.items[0].metadata.name}')" -c smoketest-collectd
    oc logs "$(oc get pod -l "job-name=stf-smoketest-${NAME}" -o jsonpath='{.items[0].metadata.name}')" -c smoketest-ceilometer
done
echo

echo "*** [INFO] Logs from qdr..."
oc logs "$(oc get pod -l application=default-interconnect -o jsonpath='{.items[0].metadata.name}')"
echo

echo "*** [INFO] Logs from smart gateways..."
oc logs "$(oc get pod -l "smart-gateway=default-cloud1-coll-meter" -o jsonpath='{.items[0].metadata.name}')" -c bridge
oc logs "$(oc get pod -l "smart-gateway=default-cloud1-coll-meter" -o jsonpath='{.items[0].metadata.name}')" -c sg-core
oc logs "$(oc get pod -l "smart-gateway=default-cloud1-coll-event" -o jsonpath='{.items[0].metadata.name}')" -c bridge
oc logs "$(oc get pod -l "smart-gateway=default-cloud1-coll-event" -o jsonpath='{.items[0].metadata.name}')" -c sg-core
oc logs "$(oc get pod -l "smart-gateway=default-cloud1-ceil-meter" -o jsonpath='{.items[0].metadata.name}')" -c bridge
oc logs "$(oc get pod -l "smart-gateway=default-cloud1-ceil-meter" -o jsonpath='{.items[0].metadata.name}')" -c sg-core
oc logs "$(oc get pod -l "smart-gateway=default-cloud1-ceil-event" -o jsonpath='{.items[0].metadata.name}')" -c bridge
oc logs "$(oc get pod -l "smart-gateway=default-cloud1-ceil-event" -o jsonpath='{.items[0].metadata.name}')" -c sg-core
echo

echo "*** [INFO] Logs from smart gateway operator..."
oc logs "$(oc get pod -l app=smart-gateway-operator -o jsonpath='{.items[0].metadata.name}')"
echo

echo "*** [INFO] Logs from prometheus..."
oc logs "$(oc get pod -l prometheus=default -o jsonpath='{.items[0].metadata.name}')" -c prometheus
echo

echo "*** [INFO] Logs from elasticsearch..."
oc logs "$(oc get pod -l common.k8s.elastic.co/type=elasticsearch -o jsonpath='{.items[0].metadata.name}')"
echo

echo "*** [INFO] Logs from snmp webhook..."
oc logs "$(oc get pod -l app=default-snmp-webhook -o jsonpath='{.items[0].metadata.name}')"
echo

echo "*** [INFO] Cleanup resources..."
oc delete job/stf-smoketest-${NAME}
echo

if [ $SNMP_WBHOOK_POD -eq 0 ]; then
    echo "*** [FAILURE] SNMP Webhook failed"
    exit 1
fi

if [ $RET -eq 0 ]; then
    echo "*** [SUCCESS] Smoke test job completed successfully"
else
    echo "*** [FAILURE] Smoke test job still not succeeded after ${JOB_TIMEOUT}"
fi
echo

exit $RET
