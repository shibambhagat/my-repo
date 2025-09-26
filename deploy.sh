#!/bin/bash
set -e

# -------------------------
# Dynamic Variables
# -------------------------
_COMMIT_SHA="$1"
_TEMPLATE="it-${_COMMIT_SHA}"
_MIG="green-mig-${_COMMIT_SHA}"
_ZONE="asia-south1-a"
_BACKEND_SERVICE="demo-backend"
_HEALTH_CHECK="demo-hc" # Make sure this is the correct Health Check Name
_PROJECT_ID="third-octagon-465311-r5"
_SERVICE_ACCOUNT="469028311605-compute@developer.gserviceaccount.com"
_IMAGE_REGISTRY="asia-south1-docker.pkg.dev/third-octagon-465311-r5/artifact-repo/simple-web-app"
FULL_IMAGE_URL="${_IMAGE_REGISTRY}:${_COMMIT_SHA}"
MIN_INSTANCES=2 # Start with 2 instances
MAX_INSTANCES=5
MAX_UTILIZATION=0.6

# -------------------------
# Create startup script file (Friend's logic, but simplified Docker install)
# -------------------------
echo "Creating startup script..."
cat > startup.sh << EOL
#!/bin/bash
set -e

# --- Install Docker ---
apt-get update -y
apt-get install -y docker.io > /dev/null 2>&1
systemctl enable docker
systemctl start docker
sleep 5 # Give Docker daemon a moment to stabilize

# --- Authenticate Docker ---
gcloud auth configure-docker asia-south1-docker.pkg.dev --quiet

# --- Get TAG (already in script for safety) ---
IMAGE_TAG="${_COMMIT_SHA}"

# --- Pull and run Docker container (Exposing 8080 inside) ---
docker pull ${FULL_IMAGE_URL}
docker rm -f simple-web-app || true
# Map VM's port 8080 to container's port 8080
docker run -d \\
  --restart=always \\
  --name simple-web-app \\
  -p 8080:8080 \\
  ${FULL_IMAGE_URL}

# --- Verify container is running inside VM before startup script exits ---
sleep 30 
if ! curl -sf http://localhost:8080/ > /dev/null; then
  echo "ERROR: Container not responding on port 8080!" >> /var/log/startup-script.log
  docker logs simple-web-app >> /var/log/startup-script.log
  exit 1
fi
echo "✅ Docker container running with image tag: \${IMAGE_TAG}" >> /var/log/startup-script.log
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
# Create new MIG (Use friend's robust args: health-check & initial-delay)
# -------------------------
gcloud compute instance-groups managed create "${_MIG}" \
--base-instance-name="${_MIG}" \
--size=2 \
--template="${_TEMPLATE}" \
--zone="${_ZONE}" \
--health-check="${_HEALTH_CHECK}" \
--initial-delay=60 \
--quiet

# -------------------------
# Add named port mapping (Using 8080 as per your previous setup)
# -------------------------
echo "🔧 Setting named port 'http:8080' for MIG ${_MIG}"
gcloud compute instance-groups set-named-ports "${_MIG}" \
--named-ports=http:8080 \
--zone="${_ZONE}" \
--quiet

# -------------------------
# Wait for MIG health
# -------------------------
echo "⏳ Waiting for new MIG to become healthy (max 300s)..."
timeout=300
interval=15
elapsed=0
healthy=false

while [[ $elapsed -lt $timeout ]]; do
status=$(gcloud compute instance-groups managed list-instances "${_MIG}" \
--zone="${_ZONE}" \
--format="value(instanceStatus)" | grep -v "RUNNING" || true)

# If status is empty, all instances are RUNNING and presumably healthy.
if [[ -z "$status" ]]; then 
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
# Enable autoscaling for the new MIG
# -------------------------
echo "⚙️ Setting autoscaling for MIG ${_MIG} (min: ${MIN_INSTANCES}, max: ${MAX_INSTANCES})"
gcloud compute instance-groups managed set-autoscaling "${_MIG}" \
  --zone="${_ZONE}" \
  --min-num-replicas="${MIN_INSTANCES}" \
  --max-num-replicas="${MAX_INSTANCES}" \
  --target-cpu-utilization=${MAX_UTILIZATION} \
  --cool-down-period=60 \
  --quiet

# -------------------------
# Attach new MIG to Load Balancer backend
# -------------------------
echo "🔀 Attaching new MIG ${_MIG} to backend service ${_BACKEND_SERVICE}"
gcloud compute backend-services add-backend "${_BACKEND_SERVICE}" \
--instance-group="${_MIG}" \
--instance-group-zone="${_ZONE}" \
--global \
--quiet

# -------------------------
# Update backend max utilization (Optional, but robust for Blue/Green)
# -------------------------
echo "🔧 Setting max backend utilization (${MAX_UTILIZATION}) for LB backend ${_BACKEND_SERVICE}"
gcloud compute backend-services update-backend "${_BACKEND_SERVICE}" \
  --instance-group="${_MIG}" \
  --instance-group-zone="${_ZONE}" \
  --global \
  --balancing-mode=UTILIZATION \
  --max-utilization=${MAX_UTILIZATION} \
  --quiet

echo "⏳ Waiting 30s for new MIG to warm up and serve traffic..."
sleep 30

# -------------------------
# Detach and delete all old MIGs (FLUSH LEFT)
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

# Wait until MIG is fully detached
echo "⏳ Waiting for ${_MIG_NAME} to be detached..."
while gcloud compute backend-services describe "${_BACKEND_SERVICE}" --global --format="value(backends.group)" | grep -q "${_MIG_NAME}"; do
sleep 5
done
echo "✅ MIG ${_MIG_NAME} detached successfully."

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
