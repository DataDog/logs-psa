#!/bin/bash
# Quick hacky script to do all the deploy things for quicker iteration

# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

fakever=$(date +%s)
echo "============="
echo "${fakever}"
echo "============="

mvn clean install -f ./multiline-poc/pom.xml

set -x

docker build . -t multiline-poc:$fakever

minikube image load multiline-poc:$fakever

# un-comment last set if you do not want to use log annotations
helm upgrade multiline-poc ./k8s/multiline-poc/ --install \
    -f ./k8s/multiline-poc/values.yaml \
    --set-string image.tag="${fakever}" \
    #--set agents.containers.agent.envDict.DD_LOGS_CONFIG_AUTO_MULTI_LINE_EXTRA_PATTERNS='(..@timestamp|\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})'
