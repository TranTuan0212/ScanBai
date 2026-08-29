const redis = require('./redisClient');

const LOCK_TTL_SECONDS = 15;

/**
 * Acquire Atomic Live Lock for userId
 * @param {string} userId 
 * @param {string} lockToken 
 * @param {number} ttlSeconds 
 * @returns {Promise<boolean>}
 */
async function acquireLiveLock(userId, lockToken, ttlSeconds = LOCK_TTL_SECONDS) {
  const key = `live_lock:${userId}`;
  const result = await redis.set(key, lockToken, 'EX', ttlSeconds, 'NX');
  return result === 'OK';
}

/**
 * Renew Live Lock TTL using Lua script to ensure token ownership
 * @param {string} userId 
 * @param {string} lockToken 
 * @param {number} ttlSeconds 
 * @returns {Promise<boolean>}
 */
async function renewLiveLock(userId, lockToken, ttlSeconds = LOCK_TTL_SECONDS) {
  const key = `live_lock:${userId}`;
  const luaScript = `
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("expire", KEYS[1], ARGV[2])
    else
      return 0
    end
  `;
  const result = await redis.eval(luaScript, 1, key, lockToken, ttlSeconds);
  return result === 1;
}

/**
 * Safely release Live Lock using Lua script
 * @param {string} userId 
 * @param {string} lockToken 
 * @returns {Promise<boolean>}
 */
async function releaseLiveLock(userId, lockToken) {
  const key = `live_lock:${userId}`;
  const luaScript = `
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  `;
  const result = await redis.eval(luaScript, 1, key, lockToken);
  return result === 1;
}

/**
 * Get current lock token for userId
 * @param {string} userId 
 * @returns {Promise<string|null>}
 */
async function getLiveLockToken(userId) {
  const key = `live_lock:${userId}`;
  return await redis.get(key);
}

module.exports = {
  LOCK_TTL_SECONDS,
  acquireLiveLock,
  renewLiveLock,
  releaseLiveLock,
  getLiveLockToken
};
