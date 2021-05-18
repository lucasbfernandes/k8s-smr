#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

readonly KIND_VERSION=${KIND_VERSION:-v0.10.0}
readonly HELM_VERSION=3.5.4
readonly CLUSTER_NAME=chart-testing
readonly ROOT=${CI_PROJECT_DIR:-$PWD}
readonly KUBECONFIG_PATH=$HOME/.kube/$CLUSTER_NAME.kubeconfig
readonly HELM_CONTAINER_NAME=helm_builder

install_kind() {
    if ! which kind >/dev/null; then
        echo 'Installing Kind'
        curl -sSLo /tmp/kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64"
        chmod +x /tmp/kind
        mv /tmp/kind /usr/local/bin/kind
    else
        echo 'Skipping Kind installation'
    fi
    echo $(kind --version)
}

create_kind_cluster() {
    echo 'Create Kind cluster'
    kind delete cluster --name "$CLUSTER_NAME" > /dev/null 2>&1 || true
    kind create cluster \
      --name "$CLUSTER_NAME" \
      --kubeconfig $KUBECONFIG_PATH \
      --config $ROOT/test/e2e/setup/kind-config.yaml
}

run_helm_builder_container() {
    echo 'Creating helm builder container'
    docker kill $HELM_CONTAINER_NAME > /dev/null 2>&1 || true
    docker run -it -d \
      --entrypoint '/bin/sh' \
      --network host \
      --name $HELM_CONTAINER_NAME \
      --volume $ROOT/test/e2e/charts:/e2e/charts \
      --volume $ROOT/install:/e2e/install \
      --workdir /e2e \
      dtzar/helm-kubectl:$HELM_VERSION

    echo 'Copying kubeconfig to container'
    docker exec -i $HELM_CONTAINER_NAME mkdir -p /root/.kube
    docker cp $KUBECONFIG_PATH $HELM_CONTAINER_NAME:/root/.kube/config

    echo 'Deploying helm applications'
    docker exec -i $HELM_CONTAINER_NAME \
      kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml

    # TODO improve this
    sleep 20

    docker exec -i $HELM_CONTAINER_NAME \
      kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=90s

    docker exec -i $HELM_CONTAINER_NAME helm install atomix install/helm-chart --atomic --debug
    docker exec -i $HELM_CONTAINER_NAME helm install counter-app charts/counter --atomic --debug

    echo 'Killing helm container'
    docker kill $HELM_CONTAINER_NAME > /dev/null 2>&1 || true
}

main() {
    install_kind
    create_kind_cluster
    run_helm_builder_container
}

main