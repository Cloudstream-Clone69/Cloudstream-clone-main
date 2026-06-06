import config from '../config.js';
import { info, warn } from '../logger.js';

export function wrapProvider(provider, name = 'unknown') {
  const cache = new Map();

  function getCacheKey(key) {
    return `${name}:${key}`;
  }

  async function cachedCall(key, fn, ...args) {
    const fullKey = getCacheKey(key);
    if (cache.has(fullKey)) {
      const { data, timestamp } = cache.get(fullKey);
      if (Date.now() - timestamp < config.cacheTTL) {
        info(`[${name}] Cache hit for ${fullKey}`);
        return data;
      }
    }
    try {
      const data = await fn(...args);
      cache.set(fullKey, { data, timestamp: Date.now() });
      return data;
    } catch (err) {
      warn(`[${name}] Error in ${fn.name}: ${err.message}`);
      throw err;
    }
  }

  return {
    search: (query) => cachedCall(`search-${query}`, provider.search, query),
    load: (url) => cachedCall(`load-${url}`, provider.load, url),
    getStreams: (url) => cachedCall(`stream-${url}`, provider.getStreams, url),
    clearCache: () => {
      for (const key of cache.keys()) {
        if (key.startsWith(name)) cache.delete(key);
      }
    },
  };
}
