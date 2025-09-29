#!/bin/bash
set -e

# -------------------------
# Dynamic Variables (Unchanged and Correct)
# -------------------------
_COMMIT_SHA="$1"
_TEMPLATE="it-${_COMMIT_SHA}"
_MIG="green-mig-${_COMMIT_SHA}"
_ZONE="asia-south1-a"
_BACKEND_SERVICE="demo-backend"
_HEALTH_CHECK="demo-hc" 
_PROJECT_ID="third-octagon-465311-r5"
_SERVICE_ACCOUNT="469028311605-compute@developer.gserviceaccount.com"
_IMAGE_REGISTRY="asia-south1-docker.pkg.dev/third-octagon-465311-r5/artifact-repo/simple-web-app"
FULL_IMAGE_URL="${_IMAGE_REGISTRY}:${_COMMIT_SHA}"
MIN_INSTANCES=2
MAX_INSTANCES=5
MAX_UTILIZATION=0.6

# -------------------------
# Create startup script file (FINAL HARDENED VERSION)
# -------------------------
echo "Creating startup script..."
cat > startup.sh << 'EOF'
#!/bin/bash
# Log file for troubleshooting
LOG_FILE="/var/log/startup-script.log"
exec > >(tee -a $LOG_FILE) 2>&1
echo "--- Starting startup script at $(date) ---"

# --- 1. Install Docker and Tools ---
echo "Updating packages and installing Docker..."
apt-get update -y
apt-get install -y docker.io -y

# CRITICAL FIX 1: Start Docker and ensure it's enabled
systemctl start docker
systemctl enable docker

# CRITICAL FIX 2: Wait 10 seconds for the Docker daemon to fully initialize
sleep 10
echo "Docker service started and stabilized."

# --- 2. Authenticate to Artifact Registry ---
IMAGE_TAG=$(curl -H "Metadata-Flavor:Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/IMAGE_TAG)
IMAGE_REGISTRY="asia-south1-docker.pkg.dev/third-octagon-465311-r5/artifact-repo/simple-web-app"
FULL_IMAGE_URL="${IMAGE_REGISTRY}:${IMAGE_TAG}"
CONTAINER_NAME="simple-web-app"
PORT=8080

echo "Authenticating to Artifact Registry..."
/usr/bin/gcloud auth configure-docker asia-south1-docker.pkg.dev --quiet

# --- 3. Pull and run the container image ---
echo "Pulling image: ${FULL_IMAGE_URL}"
docker pull ${FULL_IMAGE_URL}

echo "Stopping old container if exists..."
docker rm -f ${CONTAINER_NAME} || true

echo "Running container on port ${PORT}..."
# CRITICAL: -p 8080:8080 maps VM's external port 8080 to container's internal port 8080
docker run -d \
  --restart=always \
  --name ${CONTAINER_NAME} \
  -p ${PORT}:${PORT} \
  ${FULL_IMAGE_URL}

# --- 4. Final Verification and Logging ---
sleep 15
# CRITICAL FIX 3: Change internal VM check to use the correct /health path.
# This ensures we test the same path the LB uses.
if ! curl -sSf http://localhost:${PORT}/health > /dev/null; then
  echo "❌ ERROR: Container not responding to /health check on port ${PORT}!"
  docker logs ${CONTAINER_NAME}
  # Log running containers/processes for deep debugging before exit
  docker ps -a
  journalctl -u docker.service
  exit 1
fi
echo "✅ Container deployment completed successfully."
echo "--- Startup script finished ---"
EOF

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
# Check for instances that are NOT RUNNING (i.e., status is NOT RUNNING, or status is null)
status=$(gcloud compute instance-groups managed list-instances "${_MIG}" \
--zone="${_ZONE}" \
--format="value(instanceStatus)" | grep -v "RUNNING" || true)

# If status is empty, all instances are RUNNING.
if [[ -z "$status" ]]; then 
  echo "✅ MIG ${_MIG} instances are RUNNING."
  # Now wait for the Load Balancer Health Check to confirm health (wait 60 more seconds)
  echo "⏳ Waiting 60s for health checks to cycle..."
  sleep 60
  
  # Check instance health status in the MIG
  # The status field here is the *actual* health check status, not instance lifecycle status.
  health_status=$(gcloud compute instance-groups managed list-instances "${_MIG}" \
      --zone="${_ZONE}" \
      --format="value(healthStatus)" | grep -v "HEALTHY" || true)
      
  if [[ -z "$health_status" ]]; then
      echo "✅ MIG ${_MIG} instances are HEALTHY via Load Balancer."
      healthy=true
      break
  else
      echo "⚠️ Instances are RUNNING but Load Balancer health check status is: $health_status"
  fi
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
