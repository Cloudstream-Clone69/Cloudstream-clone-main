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
import { SocksProxyAgent } from 'socks-proxy-agent';

// ── Apply Cloudflare DNS at module load ────────────────────────────────────────
// (Can be overridden later via the /api/settings/dns endpoint)
try {
  dns.setServers(['1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4']);
  console.log('[dnsAxios] DNS set to Cloudflare + Google');
} catch (e) {
  console.warn('[dnsAxios] Could not set DNS servers:', e.message);
}

let isSlowMode = false;

export function setSlowMode(val) {
  isSlowMode = !!val;
  rebuildDnsAgents();
  console.log('[dnsAxios] Slow connection mode adjusted in Axios agents:', isSlowMode);
}

export function getSlowMode() {
  return isSlowMode;
}

const dnsCache = new Map();
const CACHE_TTL = 30 * 60 * 1000; // 30 minutes

function makeAgents() {
  const timeoutVal = isSlowMode ? 45000 : 15000;
  return {
    http:  new http.Agent({
      lookup: customLookup,
      keepAlive: true,
      keepAliveMsecs: 10000,
      maxSockets: 200,
      maxFreeSockets: 50,
      timeout: timeoutVal,
      freeSocketTimeout: 30000
    }),
    https: new https.Agent({
      lookup: customLookup,
      keepAlive: true,
      keepAliveMsecs: 10000,
      maxSockets: 200,
      maxFreeSockets: 50,
      timeout: timeoutVal,
      freeSocketTimeout: 30000,
      rejectUnauthorized: false
    }),
  };
}

function resolveDohProvider(hostname, ip) {
  return new Promise((resolve) => {
    let resolved = false;
    const hardTimeout = setTimeout(() => {
      if (resolved) return;
      resolved = true;
      try { req.destroy(); } catch (_) {}
      resolve(null);
    }, isSlowMode ? 10000 : 4000);

    const req = https.get(`https://${ip}/dns-query?name=${encodeURIComponent(hostname)}&type=A`, {
      headers: { 'accept': 'application/dns-json' },
      timeout: isSlowMode ? 8000 : 3000,
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (resolved) return;
        clearTimeout(hardTimeout);
        resolved = true;
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
    req.on('error', () => {
      if (resolved) return;
      clearTimeout(hardTimeout);
      resolved = true;
      resolve(null);
    });
    req.on('timeout', () => {
      if (resolved) return;
      clearTimeout(hardTimeout);
      resolved = true;
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

let consecutiveResolve4Timeouts = 0;
let forceDohPrimary = false;

// List of hostnames or domains to always resolve via DoH directly (bypassing UDP resolve4 blocks)
const FORCE_DOH_DOMAINS = [
  'themoviedb.org',
  'zephyrflick.top',
  'as-cdn',
  'megaplay',
  'nekostream',
  'imgcdn.kim',
  'freecdn',
  'subscdn',
  '4khdhub',
  'netmirror',
  'watchanimeworld',
  'animesalt'
];

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

  const shouldForceDoh = forceDohPrimary || FORCE_DOH_DOMAINS.some(domain => hostname.includes(domain));

  if (shouldForceDoh) {
    resolveDoh(hostname).then(ips => {
      if (ips && ips.length > 0) {
        handleIps(ips);
      } else {
        fallbackLookup();
      }
    });
    return;
  }

  let resolved = false;
  const timeoutId = setTimeout(() => {
    if (resolved) return;
    resolved = true;
    consecutiveResolve4Timeouts++;
    if (consecutiveResolve4Timeouts >= 2 && !forceDohPrimary) {
      forceDohPrimary = true;
      console.warn('[dnsAxios] Multiple dns.resolve4 timeouts. Forcing DoH primary resolver.');
    }
    console.warn(`[dnsAxios] dns.resolve4 timed out for ${hostname}. Trying DoH fallback...`);
    resolveDoh(hostname).then(ips => {
      if (ips && ips.length > 0) {
        handleIps(ips);
      } else {
        fallbackLookup();
      }
    });
  }, 1200); // slightly shorter timeout for quicker fallback

  dns.resolve4(hostname, (err, ipAddresses) => {
    if (resolved) return;
    clearTimeout(timeoutId);
    resolved = true;

    if (!err && Array.isArray(ipAddresses) && ipAddresses.length > 0) {
      consecutiveResolve4Timeouts = 0; // reset on success
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

let _agents = makeAgents();

let isWarpActive = false;
let warpProxyUrl = null;

/**
 * Call after dns.setServers() OR when enabling/disabling WARP.
 * Pass warp agents to route through SOCKS5; pass nothing to use Cloudflare DNS.
 */
export function rebuildDnsAgents(warpHttpAgent = null, warpHttpsAgent = null, proxyUrl = null) {
  if (warpHttpAgent && warpHttpsAgent) {
    _agents.http  = warpHttpAgent;
    _agents.https = warpHttpsAgent;
    isWarpActive = true;
    warpProxyUrl = proxyUrl || 'socks5://127.0.0.1:40000';
    console.log('[dnsAxios] Using WARP SOCKS5 proxy agents');
  } else {
    _agents = makeAgents();
    isWarpActive = false;
    warpProxyUrl = null;
    console.log('[dnsAxios] Using Cloudflare DNS agents. Servers:', dns.getServers());
  }
}

// ── Stream Axios factory (no idle timeouts for video streaming) ───────────────
export function createStreamAxios() {
  const agents = {
    http: new http.Agent({
      keepAlive: true,
      keepAliveMsecs: 15000,
      maxSockets: 200,
      maxFreeSockets: 50,
      timeout: 0, // NO idle socket timeout for video streaming!
      freeSocketTimeout: 60000
    }),
    https: new https.Agent({
      keepAlive: true,
      keepAliveMsecs: 15000,
      maxSockets: 200,
      maxFreeSockets: 50,
      timeout: 0, // NO idle socket timeout for video streaming!
      freeSocketTimeout: 60000,
      rejectUnauthorized: false
    })
  };

  const instance = axios.create({
    timeout: 0, // NO axios timeout for streaming!
    maxRedirects: 15,
    validateStatus: () => true,
  });

  instance.interceptors.request.use(cfg => {
    if (isWarpActive && warpProxyUrl) {
      cfg.httpAgent  = new SocksProxyAgent(warpProxyUrl);
      cfg.httpsAgent = new SocksProxyAgent(warpProxyUrl);
    } else {
      cfg.httpAgent  = agents.http;
      cfg.httpsAgent = agents.https;
    }
    return cfg;
  });

  return instance;
}

// ── Direct Stream Axios factory (bypasses SOCKS5 WARP, no timeout for HLS/video stream)
export function createDirectStreamAxios() {
  const agents = {
    http: new http.Agent({
      keepAlive: true,
      keepAliveMsecs: 15000,
      maxSockets: 200,
      maxFreeSockets: 50,
      timeout: 0,
      freeSocketTimeout: 60000
    }),
    https: new https.Agent({
      keepAlive: true,
      keepAliveMsecs: 15000,
      maxSockets: 200,
      maxFreeSockets: 50,
      timeout: 0,
      freeSocketTimeout: 60000,
      rejectUnauthorized: false
    })
  };

  const instance = axios.create({
    timeout: 0,
    maxRedirects: 15,
    validateStatus: () => true,
  });

  instance.interceptors.request.use(cfg => {
    // ALWAYS bypass WARP SOCKS5 proxy for video streaming and download traffic
    // to utilize max direct bandwidth and prevent connection resets/drops.
    cfg.httpAgent  = agents.http;
    cfg.httpsAgent = agents.https;
    return cfg;
  });

  return instance;
}

// ── Direct Axios factory (bypasses SOCKS5 WARP tunnel, uses custom DNS) ───────
export function createDirectAxios(extra = {}) {
  const agents = {
    http: new http.Agent({
      lookup: customLookup,
      keepAlive: true,
      keepAliveMsecs: 10000,
      maxSockets: 100,
      maxFreeSockets: 10,
      timeout: 10000,
      freeSocketTimeout: 15000
    }),
    https: new https.Agent({
      lookup: customLookup,
      keepAlive: true,
      keepAliveMsecs: 10000,
      maxSockets: 100,
      maxFreeSockets: 10,
      timeout: 10000,
      freeSocketTimeout: 15000,
      rejectUnauthorized: false
    })
  };

  const instance = axios.create({
    timeout: 10000,
    maxRedirects: 5,
    validateStatus: () => true,
    ...extra,
  });

  instance.interceptors.request.use(cfg => {
    cfg.httpAgent  = agents.http;
    cfg.httpsAgent = agents.https;
    return cfg;
  });

  return instance;
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
    if (isSlowMode) {
      if (!cfg.timeout || cfg.timeout < 60000) {
        cfg.timeout = 60000;
      }
    }
    return cfg;
  });

  return instance;
}

export const dnsAxios = createAxios();
