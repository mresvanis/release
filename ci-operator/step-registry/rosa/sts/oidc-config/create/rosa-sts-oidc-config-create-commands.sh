#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

OIDC_CONFIG_PREFIX=${OIDC_CONFIG_PREFIX:-$NAMESPACE}
OIDC_CONFIG_MANAGED=${OIDC_CONFIG_MANAGED:-true}

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}


# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi
AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

# Switches
MANAGED_SWITCH="--managed=${OIDC_CONFIG_MANAGED}"
if [[ "$OIDC_CONFIG_MANAGED" == "false" ]]; then
  # ACCOUNT_ROLES_PREFIX=$(cat "${SHARED_DIR}/account-roles-prefix")
  # account_installer_role_name="${ACCOUNT_ROLES_PREFIX}-Installer-Role"
  # if [[ "$HOSTED_CP" == "true" ]]; then
  #   account_installer_role_name="${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role"
  # fi
  # account_installer_role_arn=$(cat "${SHARED_DIR}/account-roles-arns" | { grep "${account_installer_role_name}" || true; })
  account_installer_role_arn=$(cat "${SHARED_DIR}/account-roles-arns" | { grep "Installer-Role" || true; })  
  MANAGED_SWITCH="${MANAGED_SWITCH} --prefix ${OIDC_CONFIG_PREFIX} --installer-role-arn ${account_installer_role_arn}"
fi

# Create oidc config
echo "Create the managed=${OIDC_CONFIG_MANAGED} oidc config ..."
rosa create oidc-config -y --mode auto --output json\
                        ${MANAGED_SWITCH} \
                        > "${SHARED_DIR}/oidc-config"
echo "Successfully create the oidc config."
oidc_config_id=$(cat "${SHARED_DIR}/oidc-config" | jq -r '.id')

# Create oidc provider
echo "Create the oidc provider based on the byo oic config ..."
rosa create oidc-provider -y --mode auto --oidc-config-id $oidc_config_id | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
echo "Successfully create the oidc provider."
