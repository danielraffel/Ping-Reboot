const axios = require('axios');

const pingURL = "http://YOURDOMAIN.COM";
const webhookURL = "YOUR_WEBHOOK_URL";
const secretPayload = { "secret": "YOUR_UNIQUE_PASSWORD" };

let consecutiveErrors = 0;

async function pingSite() {
  let responseState = "";
  try {
    const response = await axios.get(pingURL, { timeout: 10000 }); // Increased timeout to 10 seconds
    console.log(`[Ping Response] HTTP Status: ${response.status}`);

    if (response.status >= 200 && response.status < 300) {
      consecutiveErrors = 0;
      responseState = `HTTP Status: ${response.status}`;
    } else {
      consecutiveErrors++;
      responseState = `Reporting Error: ${response.status}`;
    }
  } catch (error) {
    consecutiveErrors++;
    if (error.code === 'ECONNABORTED') {
      responseState = 'Request Timeout';
    } else if (error.response) {
      responseState = `Reporting Error: ${error.response.status}`;
    } else if (error.request) {
      responseState = "Not Responding";
    } else {
      responseState = "Unknown Error";
    }
  }

  console.log(`[Processed State] ${responseState}`);

  if (consecutiveErrors >= 2) {
    await triggerWebhook(responseState);
    consecutiveErrors = 0;
  }

  return responseState;
}

async function triggerWebhook(responseState) {
  console.log("[Webhook Call] Attempting to trigger webhook...");
  try {
    const response = await axios.post(webhookURL, {
      ...secretPayload,
      "responseState": responseState
    }, { timeout: 10000 }); // Increased timeout to 10 seconds
    console.log(`[Webhook Call] Webhook triggered successfully with HTTP status: ${response.status}`);
  } catch (error) {
    console.error(`[Webhook Call] Failed to trigger webhook. HTTP Status: ${error.response?.status || "Unknown error"}`);
  }
}

exports.httpPing = async (req, res) => {
  const status = await pingSite();
  if (status.includes("Not Responding") || status.includes("Request Timeout") || status.startsWith("Reporting Error")) {
    res.status(500).send(`Site Status: ${status}`);
  } else {
    res.status(200).send(`Site Status: ${status}`);
  }
};