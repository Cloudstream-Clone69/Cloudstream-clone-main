// src/services/dnsAxios.js
// Strategy:
//   1. At startup, set DNS servers to Cloudflare 1.1.1.1 via dns.setServers().
//      This makes dns.resolve4() (c-ares based) bypass ISP DNS.
//   2. All http.Agent / https.Agent instances use a custom lookup that calls
//      dns.resolve4() instead of dns.lookup() (which uses the OS resolver
//      and ignores setServers).
//   3. When WARP is enabled, swap agents to SOCKS5 proxy agents instead.

import dns from 'dns';
import http from 'http';
import https from 'https';
import axios from 'axios';

// ── Apply Cloudflare DNS at module load ────────────────────────────────────────
// (Can be overridden later via the /api/settings/dns endpoint)
try {
  dns.setServers(['1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4']);
  console.log('[dnsAxios] DNS set to Cloudflare + Google');
} catch (e) {
  console.warn('[dnsAxios] Could not set DNS servers:', e.message);
}

const dnsCache = new Map();
const CACHE_TTL = 5 * 60 * 1000; // 5 minutes

function resolveDohProvider(hostname, ip) {
  return new Promise((resolve) => {
    const req = https.get(`https://${ip}/dns-query?name=${encodeURIComponent(hostname)}&type=A`, {
      headers: { 'accept': 'application/dns-json' },
      timeout: 3000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          const answers = json.Answer || [];
          const ips = answers.filter(a => a.type === 1).map(a => a.data);
          resolve(ips.length > 0 ? ips : null);
        } catch (_) {
          resolve(null);
        }
      });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => {
      req.destroy();
      resolve(null);
    });
  });
}

function resolveDoh(hostname) {
  return resolveDohProvider(hostname, '1.1.1.1').then(ips => {
    if (ips) return ips;
    console.log(`[dnsAxios] DoH Cloudflare failed for ${hostname}. Falling back to Google DoH...`);
    return resolveDohProvider(hostname, '8.8.8.8');
  });
}

function customLookup(hostname, options, callback) {
  const cacheKey = hostname;
  const cached = dnsCache.get(cacheKey);
  if (cached && cached.expires > Date.now()) {
    const ipAddresses = cached.ips;
    if (options && options.all) {
      return callback(null, ipAddresses.map(addr => ({ address: addr, family: 4 })));
    } else {
      return callback(null, ipAddresses[0], 4);
    }
  }

  const handleIps = (ips) => {
    dnsCache.set(cacheKey, { ips, expires: Date.now() + CACHE_TTL });
    if (options && options.all) {
      callback(null, ips.map(addr => ({ address: addr, family: 4 })));
    } else {
      callback(null, ips[0], 4);
    }
  };

  const fallbackLookup = () => {
    dns.lookup(hostname, options, (lookupErr, address, family) => {
      if (!lookupErr && address) {
        const ips = Array.isArray(address)
          ? address.map(a => typeof a === 'string' ? a : a.address)
          : [address];
        dnsCache.set(cacheKey, { ips, expires: Date.now() + CACHE_TTL });
      }
      callback(lookupErr, address, family);
    });
  };

  // Force DoH for TMDB hostnames to bypass Jio blocking reliably
  if (hostname.includes('themoviedb.org')) {
    resolveDoh(hostname).then(ips => {
      if (ips && ips.length > 0) {
        handleIps(ips);
      } else {
        fallbackLookup();
      }
    });
    return;
  }

  dns.resolve4(hostname, (err, ipAddresses) => {
    if (!err && Array.isArray(ipAddresses) && ipAddresses.length > 0) {
      handleIps(ipAddresses);
    } else {
      // Try DoH as fallback before OS resolver
      resolveDoh(hostname).then(ips => {
        if (ips && ips.length > 0) {
          handleIps(ips);
        } else {
          fallbackLookup();
        }
      });
    }
  });
}

// ── Agent management ──────────────────────────────────────────────────────────

function makeAgents() {
  return {
    http:  new http.Agent({
      lookup: customLookup,
      keepAlive: true,
      keepAliveMsecs: 1000,
      maxSockets: 100,
      maxFreeSockets: 10,
      timeout: 15000,
      freeSocketTimeout: 4000
    }),
    https: new https.Agent({
      lookup: customLookup,
      keepAlive: true,
      keepAliveMsecs: 1000,
      maxSockets: 100,
      maxFreeSockets: 10,
      timeout: 15000,
      freeSocketTimeout: 4000,
      rejectUnauthorized: false
    }),
  };
}


let _agents = makeAgents();

/**
 * Call after dns.setServers() OR when enabling/disabling WARP.
 * Pass warp agents to route through SOCKS5; pass nothing to use Cloudflare DNS.
 */
export function rebuildDnsAgents(warpHttpAgent = null, warpHttpsAgent = null) {
  if (warpHttpAgent && warpHttpsAgent) {
    _agents.http  = warpHttpAgent;
    _agents.https = warpHttpsAgent;
    console.log('[dnsAxios] Using WARP SOCKS5 proxy agents');
  } else {
    _agents = makeAgents();
    console.log('[dnsAxios] Using Cloudflare DNS agents. Servers:', dns.getServers());
  }
}

// ── Axios factory ─────────────────────────────────────────────────────────────

export function createAxios(extra = {}) {
  const instance = axios.create({
    timeout: 20000,
    maxRedirects: 10,
    validateStatus: () => true,
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
    },
    ...extra,
  });

  // Inject current agents on every request so WARP toggle takes effect instantly
  instance.interceptors.request.use(cfg => {
    cfg.httpAgent  = _agents.http;
    cfg.httpsAgent = _agents.https;
    return cfg;
  });

  return instance;
}

export const dnsAxios = createAxios();
