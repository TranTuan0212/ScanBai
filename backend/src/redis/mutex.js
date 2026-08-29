const redis = require('./redisClient');
const crypto = require('crypto');

const MUTEX_TTL_SECONDS = 3;

/**
 * Acquire distributed mutex for session updates
 * @param {string} sessionId 
 * @param {number} ttlSeconds 
 * @returns {Promise<string|null>} Returns mutex token if acquired, null otherwise
 */
async function acquireSessionMutex(sessionId, ttlSeconds = MUTEX_TTL_SECONDS) {
  const key = `mutex:session:${sessionId}`;
  const token = crypto.randomUUID();
  const result = await redis.set(key, token, 'EX', ttlSeconds, 'NX');
  return result === 'OK' ? token : null;
}

/**
 * Release distributed mutex with token verification Lua script
 * @param {string} sessionId 
 * @param {string} token 
 * @returns {Promise<boolean>}
 */
async function releaseSessionMutex(sessionId, token) {
  const key = `mutex:session:${sessionId}`;
  const luaScript = `
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  `;
  const result = await redis.eval(luaScript, 1, key, token);
  return result === 1;
}

/**
 * Execute an async operation within a session mutex lock
 * @param {string} sessionId 
 * @param {Function} task 
 * @param {number} maxRetries 
 * @param {number} retryDelayMs 
 */
async function withSessionMutex(sessionId, task, maxRetries = 10, retryDelayMs = 50) {
  let token = null;
  for (let i = 0; i < maxRetries; i++) {
    token = await acquireSessionMutex(sessionId);
    if (token) break;
    await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
  }

  if (!token) {
    throw new Error(`Failed to acquire mutex for session ${sessionId} after retries`);
  }

  try {
    return await task();
  } finally {
    await releaseSessionMutex(sessionId, token);
  }
}

module.exports = {
  acquireSessionMutex,
  releaseSessionMutex,
  withSessionMutex
};
