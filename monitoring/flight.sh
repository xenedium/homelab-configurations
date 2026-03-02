#!/bin/bash
set -e

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm install prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring --values values.yaml