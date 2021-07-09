#!/bin/sh
set -e


# Executes inside the test harness container to start collectd and look for resulting metrics in prometheus
PROMETHEUS=${PROMETHEUS:-"prometheus-operated:9090"}
ELASTICSEARCH=${ELASTICSEARCH:-"elasticsearch-es-http:9200"}
ELASTICSEARCH_AUTH_PASS=${ELASTICSEARCH_AUTH_PASS:-""}
CLOUDNAME=${CLOUDNAME:-"smoke1"}
POD=$(hostname)

# Render our config template
sed -e "s/<<CLOUDNAME>>/${CLOUDNAME}/" /etc/minimal-collectd.conf.template > /tmp/collectd.conf

echo "*** [INFO] My pod is: ${POD}"

echo "*** [INFO] Using this collectd.conf:"
cat /tmp/collectd.conf

# Run collectd in foreground mode to generate some metrics
/usr/sbin/collectd -C /tmp/collectd.conf -f 2>&1 | tee /tmp/collectd_output &

# Wait until collectd appears to be up and running
retries=3
until [ $retries -eq 0 ] || grep "Initialization complete, entering read-loop" /tmp/collectd_output; do
  retries=$((retries-1))
  echo "*** [INFO] Sleeping for 3 seconds waiting for collectd to enter read-loop"
  sleep 3
done

# Sleeping to collect 1m of actual metrics
echo "*** [INFO] Sleeping for 30 seconds to collect 30s of metrics and events"
sleep 30

echo "*** [INFO] List of metric names for debugging..."
curl -g "${PROMETHEUS}/api/v1/label/__name__/values" 2>&2 | tee /tmp/label_names
echo; echo

# Checks that the metrics actually appear in prometheus
echo "*** [INFO] Checking for recent CPU metrics..."
curl -g "${PROMETHEUS}/api/v1/query?" --data-urlencode 'query=collectd_cpu_total{container="sg-core",plugin_instance="0",type_instance="user",service="default-cloud1-coll-meter",host="'"${POD}"'"}[1m]' 2>&2 | tee /tmp/query_output
echo; echo

# The egrep exit code is the result of the test and becomes the container/pod/job exit code
echo "*** [INFO] Checking for returned CPU metrics..."
grep -E '"result":\[{"metric":{"__name__":"collectd_cpu_total","container":"sg-core","endpoint":"prom-http","host":"'"${POD}"'","plugin_instance":"0","service":"default-cloud1-coll-meter","type_instance":"user"},"values":\[\[.+,".+"\]' /tmp/query_output
metrics_result=$?
echo; echo

# Checks that the metrics actually appear in prometheus
echo "*** [INFO] Checking for recent healthcheck metrics..."
curl -g "${PROMETHEUS}/api/v1/query?" --data-urlencode 'query=sensubility_container_health_status{container="sg-core",service="default-cloud1-sens-meter",host="'"${POD}"'"}[1m]' 2>&2 | tee /tmp/query_output
echo; echo

# The egrep exit code is the result of the test and becomes the container/pod/job exit code
echo "*** [INFO] Checking for returned healthcheck metrics..."
grep -E '"result":\[{"metric":{"__name__":"sensubility_container_health_status","container":"sg-core","endpoint":"prom-http","host":"'"${POD}"'","process":"smoketest-svc","service":"default-cloud1-sens-meter"},"values":\[\[.+,".+"\]' /tmp/query_output
metrics_result=$((metrics_result || $?))
echo; echo

echo "*** [INFO] Get documents for this test from ElasticSearch..."
DOCUMENT_HITS=$(curl -sk -u "elastic:${ELASTICSEARCH_AUTH_PASS}" -X GET "https://${ELASTICSEARCH}/_search" -H 'Content-Type: application/json' -d'{
  "query": {
    "bool": {
      "filter": [
        { "term" : { "labels.instance" : { "value" : "'${CLOUDNAME}'", "boost" : 1.0 } } },
        { "range" : { "generated" : { "gte" : "now-1m", "lt" : "now" } } }
      ]
    }
  }
}' | python3 -c "import sys, json; parsed = json.load(sys.stdin); print(parsed['hits']['total']['value'])")

echo "*** [INFO] Found ${DOCUMENT_HITS} documents"
echo; echo

# check if we got documents back for this test
events_result=1
if [ "$DOCUMENT_HITS" -gt "0" ]; then
    events_result=0
fi

echo "[INFO] Verification exit codes (0 is passing, non-zero is a failure): events=${events_result} metrics=${metrics_result}"
echo; echo

if [ "$metrics_result" = "0" ] && [ "$events_result" = "0" ]; then
    echo "*** [INFO] Testing completed with success"
    exit 0
else
    echo "*** [INFO] Testing completed without success"
    exit 1
fi
