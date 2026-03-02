#!/bin/bash

set -e

kubectl apply -f preflight.yaml

helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update
helm upgrade --install external-dns external-dns/external-dns --values values.yaml --namespace ssl-dns-management

