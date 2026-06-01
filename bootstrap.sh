#!/bin/bash
set -e

GCP_PROJECT="psychotherapie-seliger-adm"
REGISTRY="europe-west10-docker.pkg.dev"
SA_NAME="k8s-image-puller"
SA_EMAIL="$SA_NAME@$GCP_PROJECT.iam.gserviceaccount.com"

# 1. Install ArgoCD via Helm (must match platform/argocd/Chart.yaml dependency)
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "9.5.17" \
  --wait

# 2. GitHub repo credentials (uses gh CLI token — no manual PAT needed)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: https://github.com/PeterLaudel
  username: git
  password: $(gh auth token)
EOF

# 3. Create dedicated GCP service account for image pulling (idempotent)
gcloud iam service-accounts create "$SA_NAME" \
  --project="$GCP_PROJECT" --display-name="Kubernetes image puller" 2>/dev/null || true

gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/artifactregistry.reader" --quiet

# 4. Generate SA key and create gcr-credentials secret per app namespace
create_gcr_secret() {
  local NAMESPACE=$1
  local KEY_FILE=$(mktemp)
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" --project="$GCP_PROJECT"
  kubectl create secret docker-registry gcr-credentials \
    --docker-server="$REGISTRY" \
    --docker-username=_json_key \
    --docker-password="$(cat $KEY_FILE)" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm "$KEY_FILE"
}

create_gcr_secret psychotherapie-seliger

# 5. Bootstrap ArgoCD
kubectl apply -f root.yml
