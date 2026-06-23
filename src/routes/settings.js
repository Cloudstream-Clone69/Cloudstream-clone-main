// src/routes/settings.js
// Handles app settings — DNS, provider toggles, etc.

import express from 'express';
import dns from 'dns';
import fs from 'fs';
import path from 'path';
import { rebuildDnsAgents } from '../services/dnsAxios.js';
import { getWarpStatus, enableWarp, disableWarp, isWarpEnabled, getProxyAgents } from '../services/warpManager.js';

const router = express.Router();
const SETTINGS_PATH = path.join(process.cwd(), 'app-settings.json');

// ── Load saved settings from disk ────────────────────────────────────────────

function loadSettings() {
  try {
    if (fs.existsSync(SETTINGS_PATH)) {
      return JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
    }
  } catch (_) {}
  return {};
}

function saveSettings(settings) {
  try {
    fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2), 'utf8');
  } catch (e) {
    console.error('[Settings] Failed to save settings:', e.message);
  }
}

// ── Apply DNS on module load (restore from saved settings) ───────────────────

const _saved = loadSettings();
if (_saved.dnsServers && Array.isArray(_saved.dnsServers) && _saved.dnsServers.length > 0) {
  try {
    dns.setServers(_saved.dnsServers);
    console.log('[Settings] Restored DNS servers:', _saved.dnsServers);
  } catch (e) {
    console.warn('[Settings] Could not restore DNS servers:', e.message);
  }
}

// ── GET /api/settings — Return current settings ───────────────────────────────

router.get('/', (req, res) => {
  const settings = loadSettings();
  // Also return currently active DNS
  try {
    settings.activeDnsServers = dns.getServers();
  } catch (_) {
    settings.activeDnsServers = [];
  }
  res.json({ success: true, settings });
});

// ── POST /api/settings/dns — Apply DNS servers ────────────────────────────────
// Body: { servers: ["1.1.1.1", "1.0.0.1"] }

router.post('/dns', (req, res) => {
  const { servers } = req.body;

  if (!Array.isArray(servers)) {
    return res.status(400).json({ success: false, error: 'servers must be an array of IP strings' });
  }

  try {
    if (servers.length === 0) {
      // Reset to system default — Node.js doesn't expose a direct reset,
      // but setting an empty array clears the override on some versions.
      // Best we can do is set a known-good fallback:
      dns.setServers(['8.8.8.8', '8.8.4.4']);
      console.log('[Settings] DNS reset to system-like defaults (8.8.8.8)');
    } else {
      dns.setServers(servers);
      console.log('[Settings] DNS set to:', servers);
    }

    // Persist to disk
    const settings = loadSettings();
    settings.dnsServers = servers.length > 0 ? servers : [];
    saveSettings(settings);

    // Rebuild axios agents so new DNS applies to ALL outgoing HTTP requests
    rebuildDnsAgents();

    res.json({ success: true, activeServers: dns.getServers() });
  } catch (e) {
    console.error('[Settings] DNS change failed:', e.message);
    res.status(500).json({ success: false, error: e.message });
  }
});

// ── POST /api/settings/providers — Toggle providers ───────────────────────────
// Body: { providers: { "4khdhub": true, "anidb": false } }

router.post('/providers', (req, res) => {
  const { providers } = req.body;
  if (!providers || typeof providers !== 'object') {
    return res.status(400).json({ success: false, error: 'providers must be an object' });
  }

  const settings = loadSettings();
  settings.providers = providers;
  saveSettings(settings);

  res.json({ success: true });
});

// ── POST /api/settings/reset — Reset all settings ────────────────────────────

router.post('/reset', (req, res) => {
  try {
    if (fs.existsSync(SETTINGS_PATH)) fs.unlinkSync(SETTINGS_PATH);
    // Reset DNS to Google as safe default
    dns.setServers(['8.8.8.8', '8.8.4.4']);
    res.json({ success: true });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// ── GET /api/settings/warp/status — WARP connection status ───────────────────

router.get('/warp/status', async (req, res) => {
  const status = await getWarpStatus();
  res.json({ success: true, status, enabled: isWarpEnabled() });
});

// ── POST /api/settings/warp/enable — Enable WARP proxy mode ──────────────────

router.post('/warp/enable', async (req, res) => {
  try {
    const ok = await enableWarp();
    if (ok) {
      // Switch all axios agents to WARP SOCKS5 proxy
      const { httpAgent, httpsAgent } = getProxyAgents();
      rebuildDnsAgents(httpAgent, httpsAgent);
      // Save preference
      const settings = loadSettings();
      settings.warpEnabled = true;
      saveSettings(settings);
      res.json({ success: true, message: 'WARP connected and proxy active' });
    } else {
      res.status(500).json({ success: false, error: 'WARP failed to connect' });
    }
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

// ── POST /api/settings/warp/disable — Disable WARP ───────────────────────────

router.post('/warp/disable', async (req, res) => {
  try {
    await disableWarp();
    rebuildDnsAgents(); // back to custom DNS agents
    const settings = loadSettings();
    settings.warpEnabled = false;
    saveSettings(settings);
    res.json({ success: true, message: 'WARP disconnected' });
  } catch (e) {
    res.status(500).json({ success: false, error: e.message });
  }
});

export default router;
