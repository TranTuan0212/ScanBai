const dgram = require('dgram');
const os = require('os');

/**
 * Get the local IPv4 address of this machine on the Wi-Fi/LAN interface
 */
function getLocalIpAddress() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal && !iface.address.startsWith('169.254')) {
        return iface.address;
      }
    }
  }
  return '127.0.0.1';
}

/**
 * Start UDP Broadcast Auto-Discovery Service
 * Allows Android apps on the same Wi-Fi to automatically find this server IP
 * @param {number} discoveryPort UDP port for discovery (default: 3001)
 * @param {number} httpPort HTTP port of the backend API (default: 3000)
 */
function startUdpDiscovery(discoveryPort = 3001, httpPort = 3000) {
  const udpServer = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  udpServer.on('error', (err) => {
    console.error('[UDP Auto-Discovery Error]', err.message);
  });

  udpServer.on('message', (msg, rinfo) => {
    const messageStr = msg.toString().trim();
    if (messageStr.includes('CARDLINK_DISCOVERY_REQUEST') || messageStr.includes('CARDLINK_DISCOVER')) {
      const localIp = getLocalIpAddress();
      const responsePayload = JSON.stringify({
        service: 'cardlink',
        ip: localIp,
        port: httpPort,
        apiUrl: `http://${localIp}:${httpPort}/api`
      });

      const responseBuffer = Buffer.from(responsePayload);
      udpServer.send(responseBuffer, 0, responseBuffer.length, rinfo.port, rinfo.address, (err) => {
        if (!err) {
          console.log(`[UDP Auto-Discovery] Responded to discovery from ${rinfo.address}:${rinfo.port} -> Server IP: ${localIp}`);
        }
      });
    }
  });

  udpServer.bind(discoveryPort, '0.0.0.0', () => {
    const localIp = getLocalIpAddress();
    console.log(`[UDP Auto-Discovery] Listening on port ${discoveryPort} (Local IP: ${localIp})`);
  });

  return udpServer;
}

module.exports = {
  getLocalIpAddress,
  startUdpDiscovery
};
