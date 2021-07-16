#!/usr/bin/env bash
set -e

if [ -n ${OCP_PROJECT+x} ]; then
    oc project $OCP_PROJECT
fi

# Play the (automated!) waiting game
echo -e "\n* [info] Waiting for QDR deployment to complete\n"
until timeout 300 oc rollout status deployment.apps/default-interconnect; do sleep 3; done
echo -e "\n* [info] Waiting for prometheus deployment to complete\n"
until timeout 300 oc rollout status statefulset.apps/prometheus-default; do sleep 3; done
echo -e "\n* [info] Waiting for elasticsearch deployment to complete \n"
while true; do
    sleep 3
    ES_READY=$(oc get statefulsets elasticsearch-es-default -ogo-template='{{ .status.readyReplicas }}') || continue
    if [ "${ES_READY}" == "1" ]; then
        break
    fi
done
echo -e "\n* [info] Waiting for alertmanager deployment to complete\n"
until timeout 300 oc rollout status statefulset.apps/alertmanager-default; do sleep 3; done
echo -e "\n* [info] Waiting for smart-gateway deployment to complete\n"
until timeout 300 oc rollout status deployment.apps/default-cloud1-coll-meter-smartgateway; do sleep 3; done
until timeout 300 oc rollout status deployment.apps/default-cloud1-coll-event-smartgateway; do sleep 3; done
until timeout 300 oc rollout status deployment.apps/default-cloud1-ceil-event-smartgateway; do sleep 3; done
until timeout 300 oc rollout status deployment.apps/default-cloud1-ceil-meter-smartgateway; do sleep 3; done
echo -e "\n* [info] Waiting for all pods to show Ready/Complete\n"
while oc get pods --selector '!openshift.io/build.name' | tail -n +2 | grep -v -E 'Running|Completed'; do
    sleep 3
done

echo -e "\n* [info] CI Build complete. You can now run tests.\n"
