# PingAndRestart

## Overview

PingAndRestart is designed to monitor and automatically restart e2 micro-instances hosted on Google Cloud that are resource-constrained. While it's a handy solution for automating non-sensitive projects, it is not intended for production environments running critical applications. 

## How It Works

The service operates through two main components:

1. **httpPing**: A cloud function that monitors the domain specified by the user every minute. It triggers an alert if it fails to receive a response from two consecutive pings.
2. **restartVMService**: Another cloud function that restarts the VM if httpPing detects an issue.

These components are orchestrated by Google Cloud Scheduler, ensuring regular checks and prompt responses to any detected issues.

## Setup

Setting up PingAndRestart is straightforward, thanks to the provided bash script. The script simplifies the process of configuring the necessary cloud functions and scheduler, along with setting up the correct service account roles.

### Prerequisites

The script requires the following tools and checks for them before running:
- `gcloud`
- `git`
- `curl`
- `expect`
- `ssh-keygen`
- `ssh-keyscan`

Instructions for installing missing prerequisites are provided in the script.
Assumes you're running on macOS.

### Getting Started

To begin using PingAndRestart:

1. **Clone the Repository**: Obtain the script by cloning the PingAndRestart repository from GitHub.
   
   ```
   git clone https://github.com/danielraffel/PingAndRestart.git
   ```

2. **Run the Script**: Navigate to the script's directory and run the main script.
   
   ```
   cd PingAndRestart
   sh main.sh
   ```

   For detailed debugging information during setup, use the debug mode:

   ```
   sh main.sh debug
   ```

### Configuration

During the setup, a bash script will prompt you to:
- Enter the external domain to monitor with a ping every minute.
- Select the Google Cloud Project hosting your server.
- Select the Google Cloud VM you wish to restart when there are two subsequent issues in a row (as defined by 400-500 errors and/or timeouts).
- Choose a Google Cloud region for deploying cloud functions.

### Deployment

The script automates the deployment process:
- It generates secure passwords, fetches your service account, and assigns roles.
- Deploys httpPing and restartVMService cloud functions.
- Sets up a Google Cloud Scheduler job for regular monitoring.
- Summarizes all the items that were created on your behalf.

### Debug Mode

For advanced users, a debug mode is available to provide detailed logs during script execution.

## Important Notes

- PingAndRestart is tailored for micro instances and is not recommended for critical production environments.
- The script assumes basic familiarity with Google Cloud Platform.
- It's crucial to review and understand the actions performed by the script to ensure it aligns with your project requirements.
- This project, with slight modifications, integrates components from [httpPing](https://github.com/danielraffel/httpPing) and [restartVMService](https://github.com/danielraffel/restartVMService). It has been repackaged for broader utility beyond its initial use for [Ghost.org](http://ghost.org).
- Initially, this tool was developed to oversee a [Ghost Blog](http://ghost.org) operating on a Google Cloud e2 micro-instance with limited resources. The blog frequently experienced downtimes, prompting the need for automation in its restart process.
- At time of publishing, assuming you're not running other Google Cloud Functions this service should fall below minimum thresholds to trigger billing costs though I would advise you to check the latest Google pricing tiers to confirm that remains the case.

## Future Items to Consider
- Implement trivial changes in `main.sh` to support installing via Linux/etc.
