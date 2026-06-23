// src/services/warpManager.js
// Manages Cloudflare WARP proxy integration.
//
// Strategy:
//   - Switch WARP to "proxy" mode (SOCKS5 on 127.0.0.1:40000)
//   - Connect WARP
//   - Configure all axios instances to route through the SOCKS5 proxy
//   - This tunnels ALL CDN traffic through Cloudflare's network, bypassing ISP blocks

import { exec } from 'child_process';
import { promisify } from 'util';
import { SocksProxyAgent } from 'socks-proxy-agent';
import axios from 'axios';

const execAsync = promisify(exec);

const WARP_CLI = 'C:\\Program Files\\Cloudflare\\Cloudflare WARP\\warp-cli.exe';
const WARP_PROXY_PORT = 40000;
const WARP_PROXY_URL = `socks5://127.0.0.1:${WARP_PROXY_PORT}`;

let _warpEnabled = false;
let _proxyAgent = null;
let _proxyHttpsAgent = null;

// ── Public API ────────────────────────────────────────────────────────────────

export function isWarpEnabled() {
  return _warpEnabled;
}

export function getProxyAgents() {
  return { httpAgent: _proxyAgent, httpsAgent: _proxyHttpsAgent };
}

/**
 * Check current WARP connection status.
 * Returns: 'Connected' | 'Disconnected' | 'Connecting' | 'Not installed'
 */
export async function getWarpStatus() {
  try {
    const { stdout } = await execAsync(`"${WARP_CLI}" status`, { timeout: 5000 });
    if (stdout.includes('Connected')) return 'Connected';
    if (stdout.includes('Connecting')) return 'Connecting';
    if (stdout.includes('Disconnected')) return 'Disconnected';
    return 'Unknown';
  } catch (e) {
    return 'Not installed';
  }
}

/**
 * Enable WARP proxy mode and connect.
 * Sets WARP to SOCKS5 proxy mode on port 40000, then connects.
 */
export async function enableWarp() {
  console.log('[WARP] Enabling WARP proxy mode...');

  // 1. Switch to proxy mode
  try {
    await execAsync(`"${WARP_CLI}" mode proxy`, { timeout: 8000 });
    console.log('[WARP] Mode set to proxy');
  } catch (e) {
    console.warn('[WARP] Mode set error (may already be in proxy mode):', e.message);
  }

  // 2. Set proxy port to 40000
  try {
    await execAsync(`"${WARP_CLI}" proxy port ${WARP_PROXY_PORT}`, { timeout: 5000 });
    console.log('[WARP] Proxy port set to', WARP_PROXY_PORT);
  } catch (e) {
    console.warn('[WARP] Port set error:', e.message);
  }

  // 3. Connect
  try {
    await execAsync(`"${WARP_CLI}" connect`, { timeout: 15000 });
    console.log('[WARP] Connect command sent');
  } catch (e) {
    console.warn('[WARP] Connect error:', e.message);
  }

  // 4. Wait for connection
  let connected = false;
  for (let i = 0; i < 12; i++) {
    await sleep(2000);
    const status = await getWarpStatus();
    console.log('[WARP] Status:', status);
    if (status === 'Connected') { connected = true; break; }
  }

  if (connected) {
    _createProxyAgents();
    _warpEnabled = true;
    console.log('[WARP] ✓ WARP proxy active on', WARP_PROXY_URL);
    return true;
  } else {
    console.error('[WARP] Failed to connect');
    return false;
  }
}

/**
 * Disable WARP and remove proxy agents.
 */
export async function disableWarp() {
  console.log('[WARP] Disconnecting WARP...');
  try {
    await execAsync(`"${WARP_CLI}" disconnect`, { timeout: 8000 });
  } catch (e) {
    console.warn('[WARP] Disconnect error:', e.message);
  }
  _warpEnabled = false;
  _proxyAgent = null;
  _proxyHttpsAgent = null;
  console.log('[WARP] WARP disabled');
  return true;
}

// ── Internal ──────────────────────────────────────────────────────────────────

function _createProxyAgents() {
  _proxyAgent = new SocksProxyAgent(WARP_PROXY_URL);
  _proxyHttpsAgent = new SocksProxyAgent(WARP_PROXY_URL);
  console.log('[WARP] SOCKS5 agents created for', WARP_PROXY_URL);
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}
