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

# Function to get the default service account
fetch_service_account() {
  SERVICE_ACCOUNT_EMAIL="${YOUR_PROJECT_ID}@appspot.gserviceaccount.com"
  debug_msg "App Engine default service account email: $SERVICE_ACCOUNT_EMAIL"
}

# Function to check and add roles to the service account
add_service_account_roles() {
  # Check and add Cloud Functions Invoker role to the project
  if ! gcloud projects get-iam-policy $YOUR_PROJECT_ID | grep -q "roles/cloudfunctions.invoker"; then
    gcloud projects add-iam-policy-binding $YOUR_PROJECT_ID \
        --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
        --role="roles/cloudfunctions.invoker"
    debug_msg "Added Cloud Functions Invoker role to project for $SERVICE_ACCOUNT_EMAIL"
  fi

  # Check and add Compute Instance Admin (v1) role to the project
  if ! gcloud projects get-iam-policy $YOUR_PROJECT_ID | grep -q "roles/compute.instanceAdmin.v1"; then
    gcloud projects add-iam-policy-binding $YOUR_PROJECT_ID \
        --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
        --role="roles/compute.instanceAdmin.v1"
    debug_msg "Added Compute Instance Admin (v1) role to project for $SERVICE_ACCOUNT_EMAIL"
  fi
}

# Function to select VM and set YOUR_STATIC_IP
select_vm_ip() {
  echo "Fetching Virtual Machine IPs..."
  vm_ips=$(gcloud compute instances list --project $YOUR_PROJECT_ID --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

  if [ -z "$vm_ips" ]; then
    echo "No Virtual Machines with external IPs found in the selected project."
    exit 1
  fi

  echo "Select the Virtual Machine IP to monitor:"
  select ip in $vm_ips; do
    YOUR_STATIC_IP=$ip
    break
  done
}

# Function to prompt user and get inputs
confirm_and_prompt() {
  read -p $'This script will create Google Cloud functions that ping your server and auto restart it if there are issues.\nShall we proceed? (Y/N) ' answer
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

  # Ask user to select a region for deploying cloud functions
  echo "Select the region closest to you for deploying cloud functions:"
  PS3="Enter your choice (1-3): "
  select region_option in "Oregon: us-west1" "Iowa: us-central1" "South Carolina: us-east1"; do
    case $region_option in
      "Oregon: us-west1") YOUR_REGION="us-west1"; break;;
      "Iowa: us-central1") YOUR_REGION="us-central1"; break;;
      "South Carolina: us-east1") YOUR_REGION="us-east1"; break;;
      *) echo "Invalid option. Please select a valid region.";;
    esac
  done

  # Google Project ID
  echo "Fetching Google Cloud project IDs..."
  project_ids=($(gcloud projects list --format="value(projectId)"))  # Store project IDs in an array

  num_projects=${#project_ids[@]}  # Get the number of projects
  echo "Select the Google Cloud Project hosting your server:"
  PS3="Enter your choice (1-$num_projects): "  # Update the prompt based on the number of projects
  select project in "${project_ids[@]}"; do
    YOUR_PROJECT_ID=$project
    break
  done

  # After selecting project, ask user to select VM IP
  select_vm_ip

  # Processing the domain to create a valid Cloud Function name
  PROCESSED_DOMAIN=$(echo $YOURDOMAIN | sed -E 's|(https?://)||' | sed -E 's|/$||' | sed -E 's|www\.||' | sed -E 's|\.([a-zA-Z0-9]+)|-\1|g' | tr '[:upper:]' '[:lower:]')
  debug_msg "Processed domain for directory: $PROCESSED_DOMAIN"

  # Generate function names based on processed domain
  FUNCTION_NAME_V2="restartVMService-${PROCESSED_DOMAIN}"
  FUNCTION_NAME_V1="httpPing-${PROCESSED_DOMAIN}"
  SCHEDULER_NAME="httpPinger-${PROCESSED_DOMAIN}"
}

# Function to deploy a cloud function and check its deployment status
deploy_cloud_function() {
  local function_name=$1
  local entry_point=$2
  local runtime=$3
  local region=$4
  local source_folder=$5
  local is_gen2=$6  # Add a parameter to indicate if the function is gen2
  local max_wait=5
  local wait_time=5
  local elapsed_time=0

  # Add a command to list the contents of the source directory
  debug_msg "Listing contents of $source_folder"
  ls -al "$source_folder"

  debug_msg "Deploying cloud function: $function_name with runtime $runtime from folder $source_folder"
  
  # Deploy the cloud function with or without the --gen2 flag
  if [ "$is_gen2" = "yes" ]; then
    gcloud functions deploy $function_name \
      --entry-point $entry_point \
      --runtime $runtime \
      --trigger-http \
      --allow-unauthenticated \
      --region $region \
      --source $source_folder \
      --gen2  # Include the --gen2 flag for v2 functions
  else
    gcloud functions deploy $function_name \
      --entry-point $entry_point \
      --runtime $runtime \
      --trigger-http \
      --allow-unauthenticated \
      --region $region \
      --source $source_folder
  fi

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
  CURRENT_DIR=$(pwd) # Get the current directory of the script

  # Use the previously processed domain
  debug_msg "Processed domain: $PROCESSED_DOMAIN"

  # Create a new directory to hold the function deployments
  DEPLOY_DIR="$CURRENT_DIR/$PROCESSED_DOMAIN" # Use absolute path
  mkdir -p "$DEPLOY_DIR/v1_functions"
  mkdir -p "$DEPLOY_DIR/v2_functions"
  debug_msg "Created directories under: $DEPLOY_DIR"

  # Copy v2 function files and update them
  debug_msg "Copying and updating v2 function files..."
  cp v2_functions/index.js v2_functions/package.json "$DEPLOY_DIR/v2_functions/"
  if [ $? -ne 0 ]; then
    echo "Error copying v2 function files to $DEPLOY_DIR/v2_functions/"
    exit 1
  else
    debug_msg "Copied v2 function files successfully."

    # Update YOUR_PROJECT_ID in the copied v2 function files
    sed -i '' "s/YOUR_PROJECT_ID/$YOUR_PROJECT_ID/g" "$DEPLOY_DIR/v2_functions/index.js"
    debug_msg "Updated YOUR_PROJECT_ID in $DEPLOY_DIR/v2_functions/index.js"

    # Update YOUR_STATIC_IP in the copied v2 function files
    sed -i '' "s/YOUR_STATIC_IP/$YOUR_STATIC_IP/g" "$DEPLOY_DIR/v2_functions/index.js"
    debug_msg "Updated YOUR_STATIC_IP in $DEPLOY_DIR/v2_functions/index.js"
  fi

  # Deploy the v2 function
  debug_msg "Deploying from source directory: $DEPLOY_DIR/v2_functions"
  deploy_cloud_function "$FUNCTION_NAME_V2" "restartVM" "nodejs18" "$YOUR_REGION" "$DEPLOY_DIR/v2_functions" "yes"
  # After deploying v2 function, retrieve URL
  YOUR_WEBHOOK_URL2=$(gcloud functions describe $FUNCTION_NAME_V2 --gen2 --region $YOUR_REGION --format="value(serviceConfig.uri)")
  debug_msg "YOUR_WEBHOOK_URL2 for v2 function: $YOUR_WEBHOOK_URL2"

  # Copy v1 function files and update them
  debug_msg "Copying and updating v1 function files..."
  cp v1_functions/index.js v1_functions/package.json "$DEPLOY_DIR/v1_functions/"
  if [ $? -ne 0 ]; then
    echo "Error copying v1 function files to $DEPLOY_DIR/v1_functions/"
    exit 1
  else
    debug_msg "Copied v1 function files successfully."

    # Update variables in the copied v1 function files
    sed -i '' "s|YOURDOMAIN|$YOURDOMAIN|g" "$DEPLOY_DIR/v1_functions/index.js"
    debug_msg "Updated YOURDOMAIN in $DEPLOY_DIR/v1_functions/index.js"

    sed -i '' "s|YOUR_WEBHOOK_URL2|$YOUR_WEBHOOK_URL2|g" "$DEPLOY_DIR/v1_functions/index.js"
    debug_msg "Updated YOUR_WEBHOOK_URL2 in $DEPLOY_DIR/v1_functions/index.js"

    sed -i '' "s|YOUR_UNIQUE_PASSWORD|$YOUR_UNIQUE_PASSWORD|g" "$DEPLOY_DIR/v1_functions/index.js"
    debug_msg "Updated YOUR_UNIQUE_PASSWORD in $DEPLOY_DIR/v1_functions/index.js"
  fi

  # Deploy the v1 function
  debug_msg "Deploying from source directory: $DEPLOY_DIR/v1_functions"
  deploy_cloud_function "$FUNCTION_NAME_V1" "httpPing" "nodejs20" "$YOUR_REGION" "$DEPLOY_DIR/v1_functions" "no"

  # Retrieve and store the URL of the deployed v1 function
  if deploy_cloud_function "$FUNCTION_NAME_V1" "httpPing" "nodejs20" "$YOUR_REGION" "$DEPLOY_DIR/v1_functions"; then
    YOUR_WEBHOOK_URL1=$(gcloud functions describe $FUNCTION_NAME_V1 --region $YOUR_REGION --format 'value(httpsTrigger.url)')
    debug_msg "YOUR_WEBHOOK_URL1 for v1 function: $YOUR_WEBHOOK_URL1"
  else
    echo "Failed to deploy $FUNCTION_NAME_V1. Exiting."
    exit 1
  fi

  # Creating Google Cloud Scheduler job named after the processed domain
  debug_msg "Creating Cloud Scheduler job named $SCHEDULER_NAME..."
  gcloud scheduler jobs create http $SCHEDULER_NAME \
    --schedule="* * * * *" \
    --uri="$YOUR_WEBHOOK_URL1" \
    --http-method="GET" \
    --location="$YOUR_REGION"

  debug_msg "Created Cloud Scheduler job: $SCHEDULER_NAME"
}

# Generate a secure password for YOUR_UNIQUE_PASSWORD
generate_secure_password() {
  YOUR_UNIQUE_PASSWORD=$(openssl rand -base64 12)
  debug_msg "Generated secure password: $YOUR_UNIQUE_PASSWORD"
}

# Function to display a completion summary
display_completion_summary() {
  echo "Script Execution Summary:"
  echo "-------------------------"
  echo "Created Cloud Functions:"
  echo "- $FUNCTION_NAME_V1: https://console.cloud.google.com/functions/"
  echo "- $FUNCTION_NAME_V2: https://console.cloud.google.com/functions/"
  echo "Created Cloud Scheduler job:"
  echo "- $SCHEDULER_NAME: https://console.cloud.google.com/cloudscheduler"
  echo "-------------------------"
  echo "You can view and manage the Cloud Functions and Scheduler job using the provided links."
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
  generate_secure_password
  fetch_service_account
  add_service_account_roles
  update_and_deploy_functions
  display_completion_summary
}

# Run the script
main $@
