#!/usr/bin/env bash

RHTAS_VERSION="" # Chart release version (used as 'version' in Chart.yaml)
CHART_VERSION="" # Trusted Artifact Signer version (used as 'appVersion' in Chart.yaml and as image tag)
CATALOG_FORK="git@github.com:openshift-helm-charts/charts.git" # Fork of "git@github.com:openshift-helm-charts/charts.git where you can push to
PUBLISH=0 # Set to True to push to CATALOG_FORK
CREATE_REPORT=0 # Set to True if you want to run https://github.com/redhat-certification/chart-verifier and create a report

# TODO switch to jq wrapper version of yq (not mikefarah)
mikefarahyq_version="4.35.2"

# Exit when any command fails
set -e

usage ()
{
    echo "Usage: $0 --chart-version x.y.z --rhtas-version x.y-zzz --rev N [--catalog <git-url>] [--debug] [--publish] 

Options:
    --publish                 Push the changes to repository specified by --catalog
    --create-report           Create a report via https://github.com/redhat-certification/chart-verifier.
                              [IMPORTANT!] Requires local user to be logged into an OCP cluster
    --catalog                 If publish is set, this needs to point to a fork of
                              git@github.com:openshift-helm-charts/charts.git with write access
    --chart-version           Chart release version (used as 'version' in Chart.yaml)
    --rhtas-version            Developer Hub version (used as 'appVersion' in Chart.yaml and as image tag)
    --debug                   Enable logging
    --help                    Prints this message

This script requires following binaries to be present on the system:
    yq         v4             https://github.com/mikefarah/yq/
    helm-docs  v1.11.0        https://github.com/norwoodj/helm-docs
    helm       v3             https://helm.sh/docs/intro/install
    git        -              https://git-scm.com/
    podman     -              https://podman.io/
    oc         -              https://console.redhat.com/openshift/downloads#tool-oc

Examples:
    Prepare and push a release to git@github.com:[your-github-fork]/openshift-helm-charts.git:

    $ $0 --chart-version 0.2.0 --rhtas-version 1.0-88 --catalog git@github.com:sallyom/openshift-helm-charts.git --publish
    Chart version:        0.2.0
    Trusted Artifact Signer image:  quay.io/rhtas/rhtas-rhel9:1.0-88

    # TODO set up a bot for this
    $ $0 --chart-version 1.0.0 --rhtas-version 1.0-zzz --catalog git@github.com:[rhtas-bot?]/openshift-helm-charts.git --publish
    Chart version:        1.0.0
    Trusted Artifact Signer image:  quay.io/rhtas/rhtas-rhel9:1.0-zzz
"
    exit
}

# Commandline args
while [[ "$#" -gt 0 ]]; do
  case $1 in
    '--publish') PUBLISH=1;;
    '--catalog') CATALOG_FORK="$2"; shift 1;;
    '--chart-version') CHART_VERSION="$2"; shift 1;;
    '--rhtas-version') RHTAS_VERSION="$2"; shift 1;;
    '--create-report') CREATE_REPORT=1;;
    '--debug') DEBUG=1;;
    '--help') usage;;
  esac
  shift 1
done

if [[ ! $RHTAS_VERSION ]]; then usage; fi

HELM_DIR=$(mktemp -d)
if [[ $DEBUG -eq 1 ]]; then echo "Running in HELM_DIR = $HELM_DIR"; fi
HELM_SOURCE_REF="main"
CATALOG_DIR=$(mktemp -d)
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# TODO switch to jq wrapper version of yq (not mikefarah)
YQ=${SCRIPT_DIR}/yq_mf
HELM_DOCS_LOG_LEVEL="fatal"

# TODO install the latest jq wrapper version of yq (not mikefarah)
# if ! command -v yq &> /dev/null; then
#     PYTHON_VERSION="3.9"
#     echo "Installing jq and yq for python $PYTHON_VERSION ..."
#     sudo dnf -y -q module install python39:${PYTHON_VERSION}
#     sudo dnf -y -q jq
#     python${PYTHON_VERSION} -m pip install --user --no-cache-dir --upgrade pip setuptools yq
# fi

if ! command -v podman &> /dev/null; then
    ocrpmrepo="https://rhsm-pulp.corp.redhat.com/content/dist/layered/rhel8/x86_64/rhocp/4.12/os/"
    echo "Installing podman from $ocrpmrepo ..."
    sudo dnf config-manager --add-repo $ocrpmrepo -q && sudo dnf -y -q install podman
fi
if ! command -v oc &> /dev/null; then
    ocrpmrepo="https://rhsm-pulp.corp.redhat.com/content/dist/layered/rhel8/x86_64/rhocp/4.12/os/"
    echo "Installing oc from $ocrpmrepo ..."
    sudo dnf config-manager --add-repo $ocrpmrepo -q && sudo dnf -y -q install openshift-clients
fi
if ! command -v helm &> /dev/null; then
    helmrpmrepo="https://rhsm-pulp.corp.redhat.com/content/dist/layered/rhel8/x86_64/ocp-tools/4.12/os/"
    echo "Installing helm from $helmrpmrepo ..."
    sudo dnf config-manager --add-repo $helmrpmrepo -q && sudo dnf -y -q install helm
fi
if ! command -v helm-docs &> /dev/null; then
    helmdocrepo=github.com/norwoodj/helm-docs/cmd/helm-docs@v1.11.2
    echo "Installing helm-docs from $helmdocrepo ..."
    sudo dnf -y -q install brotli-devel cmake gcc gcc-c++ git golang
    GO111MODULE=on go install $helmdocrepo
fi
# TODO switch to jq wrapper version of yq (not mikefarah)
if ! command -v $YQ &> /dev/null; then
    echo "Installing mikefarah yq version $mikefarahyq_version ..."
    curl -sSLo $YQ https://github.com/mikefarah/yq/releases/download/v${mikefarahyq_version}/yq_linux_amd64 && chmod +x $YQ
fi

for c in git podman oc helm helm-docs $YQ; do
    if ! command -v $c &> /dev/null; then
        echo "Command not found: '$c'"
        usage
    fi
done

if [[ $DEBUG -eq 1 ]]; then
    HELM_DOCS_LOG_LEVEL="warning"
    echo "Fetching Trusted Artifact Signer chart..."
fi

# Replace uncertified curl image with ubi9 in the test template (the file is not a valid yaml for yq)
sed -i".original" -e "s%quay.io/curl/curl:latest%registry.redhat.io/ubi9:latest%" ${HELM_DIR}/charts/trusted-artifact-signer/templates/tests/test-connection.yaml
rm ${HELM_DIR}/charts/trusted-artifact-signer/templates/tests/test-connection.yaml.original

if [[ $DEBUG -eq 1 ]]; then
    echo "Building dependencies..."
fi
helm repo add --force-update sigstore https://charts.bitnami.com/bitnami 1>/dev/null

if [[ $DEBUG -eq 1 ]]; then
    echo "Building helm deps in ${HELM_DIR}/charts/trusted-artifact-signer ..."
fi
helm dependency build ${HELM_DIR}/charts/trusted-artifact-signer 1>/dev/null

if [[ $DEBUG -eq 1 ]]; then
    echo "Fetching Helm catalog..."
fi
git clone --depth=1 -q ${CATALOG_FORK} ${CATALOG_DIR}

if [[ $DEBUG -eq 1 ]]; then
    echo "Publishing chart into the catalog..."
fi
git -C ${CATALOG_DIR} checkout -q -b trusted-artifact-signer-${CHART_VERSION}
mkdir -p ${CATALOG_DIR}/charts/redhat/redhat/trusted-artifact-signer/${CHART_VERSION}
helm package ${HELM_DIR}/charts/trusted-artifact-signer -d ${CATALOG_DIR}/charts/redhat/redhat/trusted-artifact-signer/${CHART_VERSION} 1>/dev/null

git -C ${CATALOG_DIR} add -f ${CATALOG_DIR}/charts/redhat/redhat/trusted-artifact-signer/${CHART_VERSION}/trusted-artifact-signer-${CHART_VERSION}.tgz 1>/dev/null

if [[ $CREATE_REPORT -eq 1 ]]; then
    if [[ $DEBUG -eq 1 ]]; then
        echo "Creating a report.yaml via chart-verifier..."
    fi

    # Check if it can connect to test cluster and the required pull secret exists.
    #oc get secrets/rhtas-pull-secret >/dev/null

    podman run --rm -i --platform=linux/amd64 \
        -e KUBECONFIG=/.kube/config \
        -v "${HOME}/.kube":/.kube \
        -v ${CATALOG_DIR}/charts/redhat/redhat/trusted-artifact-signer/${CHART_VERSION}:/mnt/chart \
        "quay.io/redhat-certification/chart-verifier" \
        verify --set profile.vendorType=redhat /mnt/chart/trusted-artifact-signer-${CHART_VERSION}.tgz > ${CATALOG_DIR}/charts/redhat/redhat/trusted-artifact-signer/${CHART_VERSION}/report.yaml
    git -C ${CATALOG_DIR} add -f ${CATALOG_DIR}/charts/redhat/redhat/trusted-artifact-signer/${CHART_VERSION}/report.yaml 1>/dev/null
fi

git -C ${CATALOG_DIR} commit -q --no-verify -s -S -m "chore: add trusted-artifact-signer-${CHART_VERSION}"

echo "Result:
    Chart version:        ${CHART_VERSION}
    Trusted Artifact Signer image:  quay.io/rhtas/rhtas-rhel9:${RHDH_VERSION}"

if [[ $PUBLISH -eq 1 ]]; then
    git -C ${CATALOG_DIR} push origin trusted-artifact-signer-${CHART_VERSION} | awk '/^remote: *(https.*)$/ { print "\nOpen new pull request via:\n    " $2 }'
else
    echo ""
    echo "Flag '--publish' is not set. Changes are not pushed to '$CATALOG_FORK'. Instead they can be previewed in:"
    echo ""
    echo "Repository location:  $CATALOG_DIR"
    echo "Branch:               trusted-artifact-signer-${CHART_VERSION}"
    echo "Chart folder:         $CATALOG_DIR/charts/redhat/redhat/trusted-artifact-signer/${CHART_VERSION}/"
fi

