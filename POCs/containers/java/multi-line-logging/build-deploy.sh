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

helm upgrade multiline-poc ./k8s/multiline-poc/ --install \
    -f ./k8s/multiline-poc/values.yaml \
    --set-string image.tag="${fakever}"
