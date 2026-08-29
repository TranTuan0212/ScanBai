const redis = require('./redisClient');

/**
 * Add a viewer device to the session room set
 * @param {string} sessionId 
 * @param {string} deviceId 
 */
async function addViewer(sessionId, deviceId) {
  if (!sessionId || !deviceId) return;
  const key = `room:${sessionId}:viewers`;
  await redis.sadd(key, deviceId);
}

/**
 * Remove a viewer device from the session room set
 * @param {string} sessionId 
 * @param {string} deviceId 
 */
async function removeViewer(sessionId, deviceId) {
  if (!sessionId || !deviceId) return;
  const key = `room:${sessionId}:viewers`;
  await redis.srem(key, deviceId);
}

/**
 * Get current unique viewer count (excluding broadcaster deviceId if provided)
 * @param {string} sessionId 
 * @param {string|null} broadcasterDeviceId 
 * @returns {Promise<number>}
 */
async function getViewerCount(sessionId, broadcasterDeviceId = null) {
  const key = `room:${sessionId}:viewers`;
  if (broadcasterDeviceId) {
    const isMember = await redis.sismember(key, broadcasterDeviceId);
    const total = await redis.scard(key);
    return isMember ? Math.max(0, total - 1) : total;
  }
  return await redis.scard(key);
}

/**
 * Clear all viewer tracking for a session
 * @param {string} sessionId 
 */
async function clearViewers(sessionId) {
  const key = `room:${sessionId}:viewers`;
  await redis.del(key);
}

module.exports = {
  addViewer,
  removeViewer,
  getViewerCount,
  clearViewers
};
