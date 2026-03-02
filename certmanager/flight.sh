#!/bin/bash
set -e

kubectl apply -f preflight.yaml

helm repo update
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --version v1.19.4 --set crds.enabled=true

# kubectl wait --namespace cert-manager --for=condition=available deployment/cert-manager-webhook --timeout=90s

kubectl apply -f postflight.yaml