const EventEmitter = require('events');

/**
 * High-performance In-Memory Redis Mock
 * Used for local testing and standalone execution when no external Redis server is running
 */
class InMemoryRedis extends EventEmitter {
  constructor() {
    super();
    this.store = new Map();       // key -> { value, expireAt }
    this.sets = new Map();        // key -> Set
    this.isInMemory = true;
    console.log('[Redis] Running in In-Memory Mode (Standalone/Development)');
  }

  async get(key) {
    const item = this.store.get(key);
    if (!item) return null;
    if (item.expireAt && item.expireAt <= Date.now()) {
      this.store.delete(key);
      return null;
    }
    return item.value;
  }

  async set(key, value, ...args) {
    let ttlSeconds = null;
    let onlyIfNotExist = false;

    for (let i = 0; i < args.length; i++) {
      if (args[i] === 'EX' && args[i + 1] !== undefined) {
        ttlSeconds = parseInt(args[i + 1], 10);
      }
      if (args[i] === 'NX') {
        onlyIfNotExist = true;
      }
    }

    const existing = await this.get(key);
    if (onlyIfNotExist && existing !== null) {
      return null; // NX condition failed
    }

    const expireAt = ttlSeconds ? Date.now() + ttlSeconds * 1000 : null;
    this.store.set(key, { value: String(value), expireAt });
    return 'OK';
  }

  async del(key) {
    const deleted = this.store.delete(key) || this.sets.delete(key);
    return deleted ? 1 : 0;
  }

  async expire(key, seconds) {
    const item = this.store.get(key);
    if (!item) return 0;
    item.expireAt = Date.now() + seconds * 1000;
    return 1;
  }

  async sadd(key, member) {
    if (!this.sets.has(key)) {
      this.sets.set(key, new Set());
    }
    const set = this.sets.get(key);
    const before = set.size;
    set.add(String(member));
    return set.size - before;
  }

  async srem(key, member) {
    if (!this.sets.has(key)) return 0;
    const set = this.sets.get(key);
    const deleted = set.delete(String(member));
    return deleted ? 1 : 0;
  }

  async scard(key) {
    if (!this.sets.has(key)) return 0;
    return this.sets.get(key).size;
  }

  async sismember(key, member) {
    if (!this.sets.has(key)) return 0;
    return this.sets.get(key).has(String(member)) ? 1 : 0;
  }

  async eval(script, numKeys, key, ...args) {
    // 1. Script for lock release or mutex release:
    // if redis.call("get", KEYS[1]) == ARGV[1] then return redis.call("del", KEYS[1]) else return 0 end
    if (script.includes('del')) {
      const targetVal = args[0];
      const currentVal = await this.get(key);
      if (currentVal === targetVal) {
        await this.del(key);
        return 1;
      }
      return 0;
    }

    // 2. Script for lock renewal:
    // if redis.call("get", KEYS[1]) == ARGV[1] then return redis.call("expire", KEYS[1], ARGV[2]) else return 0 end
    if (script.includes('expire')) {
      const targetVal = args[0];
      const ttlSec = parseInt(args[1], 10) || 15;
      const currentVal = await this.get(key);
      if (currentVal === targetVal) {
        await this.expire(key, ttlSec);
        return 1;
      }
      return 0;
    }

    return 0;
  }
}

module.exports = InMemoryRedis;
