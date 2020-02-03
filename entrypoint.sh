#!/bin/sh -l

GITHUB_PAT=${1}
KUBECONFIG=${2}
ORG=${3}
INFRA_REPO=${4}
PR_REF=${5}
CLUSTER=${6}
DOMAIN=${7}
IMAGE=${8}
TAG=${9}

echo "<<<< Cloning infrastructure repo ${ORG}/${INFRA_REPO}"
git clone https://${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}.git

echo ${KUBECONFIG} | base64 -d > ./kubeconfig.yaml
echo ">>>> kubeconfig created"

git config --local user.name "GitHub Action"
git config --local user.email "action@github.com"
git remote set-url origin https://x-access-token:${{secrets.GITHUB_PAT}}@github.com/${ORG}/${INFRA_REPO}
git fetch --all

echo ">>>> Compiling manifests for"
echo "ref $PR_REF"
echo "cluster $CLUSTER"
echo "domain $DOMAIN"
echo "image $IMAGE:$TAG"

cd jsonnet/${ORG}
##
# checking if this is a feature branch or release
REGEX="[a-zA-Z]+-[0-9]{1,5}"
if [[ $PR_REF =~ $REGEX ]]; then
  ##
  # If branch does not exist create it
  export BRANCH=${PR_REF:11}
  git checkout ${BRANCH} || git checkout -b ${BRANCH}

  ##
  # set namespace as jira issue id extracted from branch name and make sure it is lowercase
  export NAMESPACE=$(echo ${BASH_REMATCH[0]} |  tr '[:upper:]' '[:lower:]')

## infrastrucure branch is using master
elif [[ ${PR_REF:11} = "develop" ]]; then
  export NAMESPACE=staging
  export BRANCH=master
  git checkout master
else
  echo "<<<< $PR_REF cannot be deployed, it is not a feature branch nor a release"
fi

## compile manifests and add changes to git
docker run --rm -v $(pwd):$(pwd) --workdir $(pwd) -e CLUSTER=$CLUSTER -e DOMAIN=$DOMAIN -e NAMESPACE=$NAMESPACE -e IMAGE=$IMAGE -e TAG=$TAG quay.io/coreos/jsonnet-ci ./compile.sh
git add -A
          
## If there is nothing to commit exit without fail to continue
# this will happan if you running a deployment manually for a specific commit 
# so there will be no changes in the compiled manifests since no new docker image created
git commit -am "recompiled deployment manifests" || exit 0
git push --set-upstream origin ${BRANCH}

REGEX="[a-zA-Z]+-[0-9]{1,5}"
if [[ ${PR_REF} =~ ${REGEX} ]]; then
  export NAMESPACE=$(echo ${BASH_REMATCH[0]} |  tr '[:upper:]' '[:lower:]')
else
  echo ">>>> ${PR_REF} is not a feature branch"
  exit 0
fi

if [[ $(kubectl --kubeconfig=./kubeconfig.yaml -n argocd get application ${NAMESPACE}) ]]; then 
  echo ">>>> Application exist, OK!"
else
  echo ">>>> Creating Application"
  ./kubectl --kubeconfig=./kubeconfig.yaml -n argocd apply -f -<<EOF
kind: Application
apiVersion: argoproj.io/v1alpha1
metadata:
  name: ${NAMESPACE}
  namespace: argocd
spec:
  destination:
    namespace: ${NAMESPACE}
    server: 'https://kubernetes.default.svc'
  project: default
  source:
    path: jsonnet/${ORG}/clusters/${CLUSTER}/manifests
    INFRA_REPOURL: https://github.com/${ORG}/${INFRA_REPO}
    targetRevision: ${PR_REF:11}
  syncPolicy:
    automated: {}
EOF
fi
