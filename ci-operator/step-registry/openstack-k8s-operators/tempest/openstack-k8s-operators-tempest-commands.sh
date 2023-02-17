#!/usr/bin/env bash

set -ex

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE

oc project openstack

# Create clouds.yaml file to be used in further tests.
mkdir -p ~/.config/openstack

cat > ~/.config/openstack/clouds.yaml << EOF
$(oc get cm openstack-config -n openstack -o json | jq -r '.data["clouds.yaml"]')
EOF
export OS_CLOUD=default
KEYSTONE_SECRET_NAME=$(oc get keystoneapi keystone -o json | jq -r .spec.secret)
KEYSTONE_PASSWD_SELECT=$(oc get keystoneapi keystone -o json | jq -r .spec.passwordSelectors.admin)
OS_PASSWORD=$(oc get secret "${KEYSTONE_SECRET_NAME}" -o json | jq -r .data.${KEYSTONE_PASSWD_SELECT} | base64 -d)
export OS_PASSWORD

# Because tempestconf complain if we don't have the password in the clouds.yaml
sed -i "/project_domain_name/ a \      password: ${OS_PASSWORD}" ~/.config/openstack/clouds.yaml

# Configuring tempest

mkdir ~/tempest
pushd ~/tempest

tempest init openshift

pushd ~/tempest/openshift

discover-tempest-config --os-cloud ${OS_CLOUD} --debug --create

# Generate skiplist and allow list
ORG="openstack-k8s-operators"
# Check org and project from job's spec
REF_REPO=$(echo ${JOB_SPEC} | jq -r '.refs.repo')
REF_ORG=$(echo ${JOB_SPEC} | jq -r '.refs.org')

# Fails if step is not being used on openstack-k8s-operators repos
# Gets base repo name
BASE_OP=${REF_REPO}
if [[ "$REF_ORG" != "$ORG" ]]; then
    echo "Not a ${ORG} job. Checking if isn't a rehearsal job..."
    EXTRA_REF_REPO=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].repo')
    EXTRA_REF_ORG=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].org')
    #EXTRA_REF_BASE_REF=$(echo ${JOB_SPEC} | jq -r '.extra_refs[0].base_ref')
    if [[ "$EXTRA_REF_ORG" != "$ORG" ]]; then
      echo "Failing since this step supports only ${ORG} changes."
      exit 1
    fi
    BASE_OP=${EXTRA_REF_REPO}
fi


set +e

TEMPEST_REGEX=${TEMPEST_REGEX:-}

if [ "$TEMPEST_REGEX" ]; then
    tempest run --regex $TEMPEST_REGEX
else
    curl -O https://opendev.org/openstack/openstack-tempest-skiplist/raw/branch/master/openstack-operators/tempest_allow.yml
    curl -O https://opendev.org/openstack/openstack-tempest-skiplist/raw/branch/master/openstack-operators/tempest_skip.yml

    tempest-skip list-allowed --file tempest_allow.yml --group ${BASE_OP} --job ${BASE_OP} -f value > allow.txt
    tempest-skip list-skipped --file tempest_skip.yml --job ${BASE_OP} -f value > skip.txt
    if [ -f allow.txt ] && [ -f skip.txt ]; then
        TEMPEST_ARGS=( --exclude-list skip.txt --include-list allow.txt)
        cp allow.txt skip.txt ${ARTIFACT_DIR}
    else
        TEMPEST_ARGS=( --regex 'tempest.api.compute.admin.test_aggregates_negative.AggregatesAdminNegativeTestJSON')
    fi
    tempest run "${TEMPEST_ARGS[@]}"
fi
EXIT_CODE=$?
set -e

# Generate subunit
stestr last --subunit > testrepository.subunit || true

# Generate html
subunit2html testrepository.subunit stestr_results.html || true

# Copy stestr_results.html to artifacts directory
if [ -f stestr_results.html ]; then
    cp stestr_results.html ${ARTIFACT_DIR}
fi

exit $EXIT_CODE