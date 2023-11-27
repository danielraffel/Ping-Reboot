#!/bin/bash

# Debug flag
DEBUG_MODE="off"

# Check if debug mode is on
debug_msg() {
  if [ "$DEBUG_MODE" = "on" ]; then
    echo "Debug: $1"
  fi
}

# Check prerequisites
check_prerequisites() {
  commands=("gcloud" "git" "curl" "expect" "ssh-keygen" "ssh-keyscan")
  urls=("https://cloud.google.com/sdk/docs/install" "https://github.com/git-guides/install-git" "https://curl.se/" "https://www.digitalocean.com/community/tutorials/expect-script-ssh-example-tutorial" "https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent" "https://man.openbsd.org/ssh-keyscan.1")

  missing_flag=0
  for i in ${!commands[@]}; do
    cmd=${commands[$i]}
    url=${urls[$i]}
    if ! command -v $cmd > /dev/null 2>&1; then
      echo "$cmd is not installed. Learn more: $url"
      missing_flag=1
    fi
  done

  if [ $missing_flag -eq 1 ]; then
    echo "Exiting script due to missing prerequisites."
    exit 1
  fi
}

# Function to prompt user and get inputs
confirm_and_prompt() {
  read -p "This script will setup Google Cloud monitoring for your server. Continue? (Y/N) " answer
  case $answer in
    [Yy]* ) ;;
    * ) echo "Exiting script."; exit;;
  esac

  # Domain input
  while true; do
    read -p "Enter the domain to monitor (http://yourdomain.com): " domain
    if [[ $domain =~ ^http://.*$|^https://.*$ ]]; then
      YOURDOMAIN=$domain
      break
    else
      echo "Please enter the URL with http:// or https://"
    fi
  done

  # Confirm domain
  read -p "Monitor $YOURDOMAIN? (Y/N) " confirm_domain
  case $confirm_domain in
    [Yy]* ) ;;
    * ) confirm_and_prompt;;
  esac

  # Google Project ID
  echo "Fetching Google Cloud project IDs..."
  project_ids=$(gcloud projects list --format="value(projectId)")
  if [ -z "$project_ids" ]; then
    echo "No Google Cloud projects found. Please create a project first."
    exit 1
  fi

  echo "Available Google Cloud Projects:"
  select project in $project_ids; do
    YOUR_PROJECT_ID=$project
    break
  done

  # Processing the domain to create a valid Cloud Function name
  FUNCTION_SUFFIX=$(echo $YOURDOMAIN | sed 's|http[s]\?://||g' | sed 's/[.]/_/g')
}

# Function to deploy a cloud function and check its deployment status
deploy_cloud_function() {
  local function_name=$1
  local entry_point=$2
  local region=$YOUR_REGION
  local max_wait=240
  local wait_time=5
  local elapsed_time=0

  debug_msg "Deploying cloud function: $function_name"
  # Command to deploy the cloud function
  gcloud functions deploy $function_name --entry-point $entry_point --runtime nodejs10 --trigger-http --allow-unauthenticated --region $region

  while [ $elapsed_time -lt $max_wait ]; do
    if gcloud functions describe $function_name --region $region | grep -q "status: ACTIVE"; then
      debug_msg "$function_name deployed successfully."
      return 0
    fi
    sleep $wait_time
    elapsed_time=$((elapsed_time + wait_time))
  done

  echo "Deployment of $function_name timed out."
  return 1
}

# Function to update and deploy cloud functions
update_and_deploy_functions() {
  # Ensure the working directory is correct
  cd "$(dirname "$0")"

  # Generate function names based on domain
  FUNCTION_NAME_V2="RestartVMService_${FUNCTION_SUFFIX}"
  FUNCTION_NAME_V1="httpPing_${FUNCTION_SUFFIX}"
  SCHEDULER_NAME="httpPinger_${FUNCTION_SUFFIX}"

  # Update and deploy v2 function (RestartVMService)
  debug_msg "Updating v2 function..."
  sed -i "s/YOUR_PROJECT_ID/$YOUR_PROJECT_ID/g" v2_functions/index.js
  sed -i "s/YOUR_STATIC_IP/$YOUR_STATIC_IP/g" v2_functions/index.js

  if deploy_cloud_function "$FUNCTION_NAME_V2" "restartVM"; then
    YOUR_WEBHOOK_URL2=$(gcloud functions describe $FUNCTION_NAME_V2 --region $YOUR_REGION --format 'value(httpsTrigger.url)')
    debug_msg "$FUNCTION_NAME_V2 URL: $YOUR_WEBHOOK_URL2"
  else
    echo "Failed to deploy $FUNCTION_NAME_V2. Exiting."
    exit 1
  fi

  # Update and deploy v1 function (httpPing)
  debug_msg "Updating v1 function..."
  sed -i "s/YOURDOMAIN.COM/$YOURDOMAIN/g" v1_functions/index.js
  sed -i "s/YOUR_WEBHOOK_URL2/$YOUR_WEBHOOK_URL2/g" v1_functions/index.js
  sed -i "s/YOUR_UNIQUE_PASSWORD/$YOUR_UNIQUE_PASSWORD/g" v1_functions/index.js

  if deploy_cloud_function "$FUNCTION_NAME_V1" "httpPing"; then
    YOUR_WEBHOOK_URL1=$(gcloud functions describe $FUNCTION_NAME_V1 --region $YOUR_REGION --format 'value(httpsTrigger.url)')
    debug_msg "$FUNCTION_NAME_V1 URL: $YOUR_WEBHOOK_URL1"
  else
    echo "Failed to deploy $FUNCTION_NAME_V1. Exiting."
    exit 1
  fi

  # Creating Google Cloud Scheduler job named after the processed domain
  debug_msg "Creating Cloud Scheduler job named $SCHEDULER_NAME..."
  gcloud scheduler jobs create http $SCHEDULER_NAME --schedule="* * * * *" --uri=$YOUR_WEBHOOK_URL1 --message-body='{}' --region $YOUR_REGION

  # Setting roles for service account
  debug_msg "Setting roles for service account..."
  gcloud functions add-iam-policy-binding $FUNCTION_NAME_V2 \
      --region=$YOUR_REGION \
      --member="serviceAccount:$SERVICE_ACCOUNT@$YOUR_PROJECT_ID.iam.gserviceaccount.com" \
      --role='roles/cloudfunctions.invoker'

  gcloud projects add-iam-policy-binding $YOUR_PROJECT_ID \
      --member="serviceAccount:$SERVICE_ACCOUNT@$YOUR_PROJECT_ID.iam.gserviceaccount.com" \
      --role="roles/compute.instanceAdmin.v1"
}

# Function to set debug mode
set_debug_mode() {
  if [ "$1" = "debug" ]; then
    DEBUG_MODE="on"
  fi
}

# Main script execution
main() {
  set_debug_mode $1
  check_prerequisites
  confirm_and_prompt
  update_and_deploy_functions
}

# Run the script
main $@
