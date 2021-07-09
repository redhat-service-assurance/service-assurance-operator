#!/bin/sh
set -e

# Executes inside the test harness container to start collectd and look for resulting metrics in prometheus
PROMETHEUS=${PROMETHEUS:-"prometheus-operated:9090"}
ELASTICSEARCH=${ELASTICSEARCH:-"elasticsearch-es-http:9200"}
ELASTICSEARCH_AUTH_PASS=${ELASTICSEARCH_AUTH_PASS:-""}
CLOUDNAME=${CLOUDNAME:-"smoke1"}
POD=$(hostname)


echo "*** [INFO] My pod is: ${POD}"

# Run ceilometer_publisher script
python3 /ceilometer_publish.py default-interconnect:5671 driver=amqp&topic=metric driver=amqp&topic=event

# Sleeping to produce data
echo "*** [INFO] Sleeping for 20 seconds to produce all metrics and events"
sleep 20

echo "*** [INFO] List of metric names for debugging..."
curl -s -g "${PROMETHEUS}/api/v1/label/__name__/values" 2>&2 | tee /tmp/label_names
echo; echo

# Checks that the metrics actually appear in prometheus
echo "*** [INFO] Checking for recent image metrics..."

echo "[DEBUG] Running the curl command to return a query"
curl -g "${PROMETHEUS}/api/v1/query?" --data-urlencode 'query=ceilometer_image_size' 2>&1 | grep '"result":\[{"metric":{"__name__":"ceilometer_image_size"'
echo "[DEBUG] Query returned"
metrics_result=$?
echo "[DEBUG] Set metrics_result to $metrics_result"

echo "*** [INFO] Get documents for this test from ElasticSearch..."
DOCUMENT_HITS=$(curl -sk -u "elastic:${ELASTICSEARCH_AUTH_PASS}" -X GET "https://${ELASTICSEARCH}/_search" -H 'Content-Type: application/json' -d'{
  "query": {
    "bool": {
      "filter": [
        { "term" : { "labels.instance" : { "value" : "'${CLOUDNAME}'", "boost" : 1.0 } } },
        { "range" : { "startsAt" : { "gte" : "now-1m", "lt" : "now" } } }
      ]
    }
  }
}' | python3 -c "import sys, json; parsed = json.load(sys.stdin); print(parsed['hits']['total']['value'])")


echo "*** [INFO] List of indices for debugging..."
curl -sk -u "elastic:${ELASTICSEARCH_AUTH_PASS}" -X GET "https://${ELASTICSEARCH}/_cat/indices/ceilometer_*?s=index"
echo

echo "*** [INFO] Get documents for this test from ElasticSearch..."
ES_INDEX=ceilometer_image
DOCUMENT_HITS=$(curl -sk -u "elastic:${ELASTICSEARCH_AUTH_PASS}" -X GET "https://${ELASTICSEARCH}/${ES_INDEX}/_search" -H 'Content-Type: application/json' -d'{
  "query": {
    "match_all": {}
  }
}'| python3 -c "import sys, json; parsed = json.load(sys.stdin); print(parsed['hits']['total']['value'])")

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
