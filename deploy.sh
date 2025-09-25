#!/bin/bash
set -e

# This script is a direct adaptation of your friend's working solution.
# All variables have been updated to match your project details.

# -------------------------
# Dynamic Variables
# -------------------------
# The SHORT_SHA is passed from Cloud Build as the first argument.
_COMMIT_SHA="$1"
_TEMPLATE="it-${_COMMIT_SHA}"
_MIG="green-mig-${_COMMIT_SHA}"
_ZONE="asia-south1-a"
_BACKEND_SERVICE="demo-backend"
_PROJECT_ID="third-octagon-465311-r5"
_SERVICE_ACCOUNT="469028311605-compute@developer.gserviceaccount.com"
_IMAGE_REGISTRY="asia-south1-docker.pkg.dev/third-octagon-465311-r5/artifact-repo/simple-web-app"

# -------------------------
# Create startup script file
# -------------------------
echo "Creating startup script..."
cat > startup.sh << EOL
#!/bin/bash
apt-get update -y
apt-get install -y docker.io > /dev/null 2>&1
systemctl enable docker
systemctl start docker

# NEW: Use gcloud to get a short-lived access token and pipe it to docker login
ACCESS_TOKEN=\$(gcloud auth print-access-token --quiet)
echo "\$ACCESS_TOKEN" | docker login -u oauth2accesstoken --password-stdin https://asia-south1-docker.pkg.dev

sleep 10
docker pull ${_IMAGE_REGISTRY}:${_COMMIT_SHA}
docker stop simple-web-app || true
docker rm simple-web-app || true
docker run -d --restart=always -p 8080:8080 --name simple-web-app ${_IMAGE_REGISTRY}:${_COMMIT_SHA}
echo "Container deployment completed: \$(date)" >> /var/log/startup-script.log
EOL

chmod +x startup.sh

echo "✅ Creating new instance template: ${_TEMPLATE}"

# -------------------------
# Create new instance template
# -------------------------
gcloud compute instance-templates create "${_TEMPLATE}" \
  --metadata-from-file=startup-script=startup.sh \
  --metadata=IMAGE="${_IMAGE_REGISTRY}",IMAGE_TAG="${_COMMIT_SHA}" \
  --service-account="${_SERVICE_ACCOUNT}" \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --machine-type=e2-micro \
  --image-family=debian-11 \
  --image-project=debian-cloud \
  --quiet

echo "✅ Creating new Managed Instance Group: ${_MIG}"

# -------------------------
# Create new MIG
# -------------------------
gcloud compute instance-groups managed create "${_MIG}" \
  --base-instance-name="${_MIG}" \
  --size=2 \
  --template="${_TEMPLATE}" \
  --zone="${_ZONE}" \
  --quiet

# -------------------------
# Add named port mapping
# -------------------------
echo "🔧 Setting named port 'http:8080' for MIG ${_MIG}"
gcloud compute instance-groups set-named-ports "${_MIG}" \
  --named-ports=http:8080 \
  --zone="${_ZONE}" \
  --quiet

echo "⏳ Waiting for new MIG to become healthy (max 300s)..."
# -------------------------
# Wait for MIG health
# -------------------------
timeout=300
interval=15
elapsed=0
healthy=false

while [[ $elapsed -lt $timeout ]]; do
  status=$(gcloud compute instance-groups managed list-instances "${_MIG}" \
    --zone="${_ZONE}" \
    --format="value(instanceStatus)" || true)

  if [[ -n "$status" ]] && ! echo "$status" | grep -qv "RUNNING"; then
    echo "✅ MIG ${_MIG} instances are RUNNING."
    healthy=true
    break
  fi

  echo "⏳ Still waiting... ($elapsed/$timeout seconds)"
  sleep $interval
  elapsed=$((elapsed + interval))
done

if [[ "$healthy" != "true" ]]; then
  echo "❌ ERROR: MIG ${_MIG} failed to become healthy within $timeout seconds. Rolling back."
  gcloud compute instance-groups managed delete "${_MIG}" --zone="${_ZONE}" --quiet || true
  gcloud compute instance-templates delete "${_TEMPLATE}" --quiet || true
  exit 1
fi

# -------------------------
# Attach new MIG to Load Balancer backend
# -------------------------
echo "🔀 Attaching new MIG ${_MIG} to backend service ${_BACKEND_SERVICE}"
gcloud compute backend-services add-backend "${_BACKEND_SERVICE}" \
  --instance-group="${_MIG}" \
  --instance-group-zone="${_ZONE}" \
  --global \
  --quiet

echo "⏳ Waiting 30s for new MIG to warm up and serve traffic..."
sleep 30

# -------------------------
# Detach and delete all old MIGs
# -------------------------
echo "🗑 Detaching and deleting old MIGs from LB backend..."
attached_migs=$(gcloud compute backend-services describe "${_BACKEND_SERVICE}" --global --format="value(backends.group)" || true)

if [[ -n "$attached_migs" ]]; then
  echo "$attached_migs" | tr ';' '\n' | while read -r mig_url; do
    _MIG_NAME=$(basename "$mig_url")
    
    # Skip the new MIG
    if [[ "$_MIG_NAME" == "${_MIG}" ]]; then
      continue
    fi
    
    echo "🛑 Detaching old MIG: ${_MIG_NAME} from backend ${_BACKEND_SERVICE}"
    set +e
    gcloud compute backend-services remove-backend "${_BACKEND_SERVICE}" \
      --instance-group="${_MIG_NAME}" \
      --instance-group-zone="${_ZONE}" \
      --global \
      --quiet || true
    set -e
  done
else
  echo "No old MIGs attached to backend."
fi

# Delete all old MIGs and templates (keeping the new ones)
echo "🗑 Deleting old resources..."
old_migs=$(gcloud compute instance-groups managed list --format="value(name)" --filter="name ~ ^green-mig-" | grep -v "${_MIG}" || true)
if [[ -n "$old_migs" ]]; then
  gcloud compute instance-groups managed delete $old_migs --zone="${_ZONE}" --quiet || true
fi

old_templates=$(gcloud compute instance-templates list --format="value(name)" --filter="name ~ ^it-" | grep -v "${_TEMPLATE}" || true)
if [[ -n "$old_templates" ]]; then
  gcloud compute instance-templates delete $old_templates --quiet || true
fi

echo "✅ Deployment completed successfully with zero downtime."
