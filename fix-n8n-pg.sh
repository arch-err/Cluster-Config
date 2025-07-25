#!/usr/bin/env bash
passwd=$(kubectl get secret n8n-postgresql -n home-automation -o yaml | yq ".data.postgres-password" | base64 -d)
pod=$(kubectl get pods -n home-automation | grep n8n-postgres | awk '{print $1}')
kubectl exec $pod -- psql -U postgres -c "ALTER USER postgres WITH PASSWORD '$passwd';"
