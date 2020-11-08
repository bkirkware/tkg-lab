#!/bin/bash -e

TKG_LAB_SCRIPTS="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source $TKG_LAB_SCRIPTS/set-env.sh

CLUSTER_NAME=$(yq r $PARAMS_YAML management-cluster.name)
DEX_CN=$(yq r $PARAMS_YAML management-cluster.dex-fqdn)
OKTA_AUTH_SERVER_CN=$(yq r $PARAMS_YAML okta.auth-server-fqdn)
OKTA_DEX_APP_CLIENT_ID=$(yq r $PARAMS_YAML okta.dex-app-client-id)
OKTA_DEX_APP_CLIENT_SECRET=$(yq r $PARAMS_YAML okta.dex-app-client-secret)

kubectl config use-context $CLUSTER_NAME-admin@$CLUSTER_NAME

mkdir -p generated/$CLUSTER_NAME/dex/

# 02b-ingress.yaml
yq read tkg-extensions-mods-examples/authentication/dex/aws/oidc/02b-ingress.yaml > generated/$CLUSTER_NAME/dex/02b-ingress.yaml
yq write -d0 generated/$CLUSTER_NAME/dex/02b-ingress.yaml -i "spec.virtualhost.fqdn" $DEX_CN

# 03-certs.yaml
yq read tkg-extensions-mods-examples/authentication/dex/aws/oidc/03-certs.yaml > generated/$CLUSTER_NAME/dex/03-certs.yaml
yq write -d0 generated/$CLUSTER_NAME/dex/03-certs.yaml -i "spec.commonName" $DEX_CN
yq write -d0 generated/$CLUSTER_NAME/dex/03-certs.yaml -i "spec.dnsNames[0]" $DEX_CN

# Prepare Contour custom configuration
if [ "$IAAS" = "aws" ];
then
  # aws
  yq read tkg-extensions/extensions/authentication/dex/aws/oidc/dex-data-values.yaml.example > generated/$CLUSTER_NAME/dex/dex-data-values.yaml
else
  # vsphere
  yq read tkg-extensions/extensions/authentication/dex/vsphere/oidc/dex-data-values.yaml.example > generated/$CLUSTER_NAME/dex/dex-data-values.yaml
  yq write -d0 generated/$CLUSTER_NAME/dex/dex-data-values.yaml -i "dns.vsphere.ipAddresses[0]" $(yq r $PARAMS_YAML management-cluster.controlplane-endpoint-ip)
fi
yq write -d0 generated/$CLUSTER_NAME/dex/dex-data-values.yaml -i dex.config.oidc.CLIENT_ID $OKTA_DEX_APP_CLIENT_ID
yq write -d0 generated/$CLUSTER_NAME/dex/dex-data-values.yaml -i dex.config.oidc.CLIENT_SECRET $OKTA_DEX_APP_CLIENT_SECRET
yq write -d0 generated/$CLUSTER_NAME/dex/dex-data-values.yaml -i dex.config.oidc.issuer https://$OKTA_AUTH_SERVER_CN

# Add in the document seperator that yq removes
if [ `uname -s` = 'Darwin' ]; 
then
  sed -i '' '3i\
  ---\
  ' generated/$CLUSTER_NAME/dex/dex-data-values.yaml
else
  sed -i -e '3i\
  ---\
  ' generated/$CLUSTER_NAME/dex/dex-data-values.yaml
fi

cp tkg-extensions/extensions/authentication/dex/dex-extension.yaml  generated/$CLUSTER_NAME/dex/dex-extension.yaml

kubectl apply -f tkg-extensions/extensions/authentication/dex/namespace-role.yaml
kubectl create secret generic dex-data-values --from-file=values.yaml=generated/$CLUSTER_NAME/dex/dex-data-values.yaml -n tanzu-system-auth
kubectl apply -f generated/$CLUSTER_NAME/dex/dex-extension.yaml

while kubectl get app dex -n tanzu-system-auth | grep dex | grep "Reconcile succeeded" ; [ $? -ne 0 ]; do
	echo Dex extension is not yet ready
	sleep 5s
done   

# TODO: Need to consider the post deployment steps for AWS!!!!  

# The following bit will pause the app reconciliation, delete the selfsigned cert/secret and create lets encrypt
# signed cert/secret and then restate the dex pod

# Add paused = true to stop reconciliation
sed -i '' -e 's/syncPeriod: 5m/paused: true/g' generated/$CLUSTER_NAME/dex/dex-extension.yaml
kubectl apply -f generated/$CLUSTER_NAME/dex/dex-extension.yaml

# Wait until dex app is paused
while kubectl get app dex -n tanzu-system-auth | grep dex | grep "paused" ; [ $? -ne 0 ]; do
	echo Dex extension is not yet paused
	sleep 5s
done   

kubectl apply -f generated/$CLUSTER_NAME/dex/03-certs.yaml
kubectl apply -f generated/$CLUSTER_NAME/dex/02b-ingress.yaml.yaml

while kubectl get certificates -n tanzu-system-auth dex-cert | grep True ; [ $? -ne 0 ]; do
	echo Dex certificate is not yet ready
	sleep 5s
done   

kubectl patch deployment dex \
  -n tanzu-system-auth \
  --type json \
  -p='[{"op": "replace", "path": "/spec/template/spec/volumes/1/secret/secretName", "value":"dex-cert-tls-valid"}]'
