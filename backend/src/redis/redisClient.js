const Redis = require('ioredis');
const InMemoryRedis = require('./inMemoryRedis');
require('dotenv').config();

const redisUrl = process.env.REDIS_URL || 'redis://localhost:6379';
const forceInMemory = process.env.USE_IN_MEMORY_REDIS === 'true';

let client;

if (forceInMemory) {
  client = new InMemoryRedis();
} else {
  const inMemoryFallback = new InMemoryRedis();
  let isUsingFallback = false;

  const realRedis = new Redis(redisUrl, {
    maxRetriesPerRequest: 1,
    retryStrategy(times) {
      if (times > 2) {
        if (!isUsingFallback) {
          isUsingFallback = true;
          console.log('[Redis] Switched to built-in In-Memory Redis Store.');
        }
        return null; // Stop retrying
      }
      return 500;
    },
    lazyConnect: true
  });

  // Catch connection errors silently to avoid spamming console
  realRedis.on('error', (err) => {
    if (!isUsingFallback) {
      isUsingFallback = true;
      console.log('[Redis] External Redis offline -> Using built-in In-Memory Store.');
    }
  });

  client = new Proxy(realRedis, {
    get(target, prop) {
      if (isUsingFallback) {
        return typeof inMemoryFallback[prop] === 'function'
          ? inMemoryFallback[prop].bind(inMemoryFallback)
          : inMemoryFallback[prop];
      }
      return typeof target[prop] === 'function' ? target[prop].bind(target) : target[prop];
    }
  });

  realRedis.connect().then(() => {
    console.log('[Redis] Connected to external Redis server successfully');
  }).catch(() => {
    isUsingFallback = true;
  });
}

module.exports = client;
