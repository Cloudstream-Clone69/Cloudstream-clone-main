import { info, warn } from './logger.js';
import config from './config.js';

export function createFallbackProvider(providersMap) {
  const order = config.fallbackOrder || Object.keys(providersMap);

  async function parallelSearch(query) {
    const promises = order.map(async (provName) => {
      const provider = providersMap[provName];
      if (!provider) return [];
      try {
        info(`[Fallback] Searching on ${provName}`);
        const res = await provider.search(query);
        return res.map(item => ({ ...item, provider: provName }));
      } catch (err) {
        warn(`[Fallback] ${provName} search failed: ${err.message}`);
        return [];
      }
    });
    const resultsPerProvider = await Promise.allSettled(promises);
    const merged = [];
    for (const result of resultsPerProvider) {
      if (result.status === 'fulfilled') merged.push(...result.value);
    }
    return merged;
  }

  return {
    search: (query) => parallelSearch(query),
    // load and getStreams are NOT handled by fallback – use the provider from the result
  };
}
