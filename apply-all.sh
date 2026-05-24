#!/bin/bash
set -euo pipefail

echo "Deploying my-redis-k8s-lab..."

# Namespaces must exist before any namespaced resources are applied.
kubectl apply -f 00-namespaces/namespaces.yaml
kubectl wait --for=condition=Active \
  namespace/my-infra-space \
  namespace/my-data-space \
  namespace/my-app-space \
  --timeout=30s

# Data tier: PV first so PVC binding can occur during StatefulSet creation.
kubectl apply -f 02-my-data-space/local-pv.yaml
kubectl apply -f 02-my-data-space/configmap.yaml
kubectl apply -f 02-my-data-space/secret.yaml
kubectl apply -f 02-my-data-space/network-policy.yaml
kubectl apply -f 02-my-data-space/redis-services.yaml
kubectl apply -f 02-my-data-space/redis-statefulset.yaml

echo "Waiting for Redis StatefulSet..."
kubectl rollout status statefulset/redis-db -n my-data-space --timeout=120s

# Sync credentials to app namespace before deploying RedisInsight.
echo "Syncing redis-credentials to my-app-space..."
kubectl get secret redis-credentials -n my-data-space -o yaml | \
  sed 's/namespace: my-data-space/namespace: my-app-space/' | \
  kubectl apply -f -

# App tier: RBAC before deployment so SA exists at pod creation time.
kubectl apply -f 03-my-app-space/configmap.yaml
kubectl apply -f 03-my-app-space/serviceaccount.yaml
kubectl apply -f 03-my-app-space/role.yaml
kubectl apply -f 03-my-app-space/rolebinding.yaml
kubectl apply -f 03-my-app-space/network-policy.yaml
kubectl apply -f 03-my-app-space/redisinsight-service.yaml
kubectl apply -f 03-my-app-space/redisinsight-deployment.yaml

echo "Waiting for RedisInsight Deployment..."
kubectl rollout status deployment/redisinsight-ui -n my-app-space --timeout=120s

# Infra tier: Ingress last, after backend services are confirmed ready.
kubectl apply -f 01-my-infra-space/ingress-route.yaml

echo ""
echo "Deployment complete."
kubectl get pods -A -l project=my-redis-k8s-lab -o wide
echo ""
echo "Access: http://myredislab.dev"
echo "Hosts entry required: 10.0.0.200 myredislab.dev"