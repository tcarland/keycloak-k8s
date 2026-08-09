#!/usr/bin/env bash
# 
# Create short-lived dev certs for testing deployments
#

openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout env/dev/tls.key -out env/dev/tls.crt \
            -days 1 -subj "/CN=keycloak-dev"
