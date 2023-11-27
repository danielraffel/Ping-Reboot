const { google } = require('googleapis');
const compute = google.compute('v1');

exports.restartVM = async (req, res) => {
  console.log("Request body:", req.body);

  const secret = process.env.secret;
  const payloadSecret = req.body.secret;
  const responseState = req.body.responseState;

  if ((req.headers['x-custom-secret'] !== secret && payloadSecret !== secret) || 
      (!responseState.startsWith('Reporting Error') && responseState !== 'Not Responding' && responseState !== 'Request Timeout')) {
    return res.status(403).send('Forbidden or Not Reporting Error/Not Responding/Request Timeout');
  }

  const auth = await google.auth.getClient({
    scopes: ['https://www.googleapis.com/auth/cloud-platform']
  });

  const projectId = 'YOUR_PROJECT_ID';
  const targetIP = 'YOUR_STATIC_IP';

  const zonesResponse = await compute.zones.list({ project: projectId, auth: auth });
  const zones = zonesResponse.data.items.map(zone => zone.name);

let instanceToRestart = null;
let zoneToRestart = null;

for (const zone of zones) {
  const instancesResponse = await compute.instances.list({ project: projectId, zone: zone, auth: auth });
  const instances = instancesResponse.data.items || [];

  for (const instance of instances) {
    const instanceName = instance.name;
    const externalIP = instance.networkInterfaces?.[0]?.accessConfigs?.[0]?.natIP;

    if (externalIP === targetIP) {
      instanceToRestart = instanceName;
      zoneToRestart = zone;
      break; // Break out of the loop once a match is found
    }
  }

  if (instanceToRestart) {
    break; // Break out of the outer loop if an instance is found
  }
}

  if (instanceToRestart) {
    const request = {
      project: projectId,
      zone: zoneToRestart,
      instance: instanceToRestart,
      auth: auth
    };

    try {
      const instanceDetails = await compute.instances.get(request);
      console.log("Instance details response:", JSON.stringify(instanceDetails));

      if (!instanceDetails || !instanceDetails.data) {
        return res.status(500).send('Failed to fetch instance details');
      }

      const status = instanceDetails.data.status;

      if (status === 'RUNNING') {
        await compute.instances.reset(request);
      } else if (status === 'TERMINATED' || status === 'STOPPED') {
        await compute.instances.start(request);
      }

      console.log(`VM instance ${instanceToRestart} operation completed.`);
      res.status(200).send(`Operation completed on ${instanceToRestart}`);
    } catch (err) {
      console.error("Error:", err);
      res.status(500).send('Failed to perform operation on VM');
    }
  } else {
    res.status(404).send('No matching instance found');
  }
};