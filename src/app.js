import express from "express";
import cors from "cors";

import providersRoute from "./routes/providers.js";
import searchRoute from "./routes/search.js";
import searchAllRoute from "./routes/searchAll.js";
import detailsRoute from "./routes/details.js";
import streamRoute from "./routes/stream.js";
import proxyRoute from "./routes/proxy.js";
import homeRoute from "./routes/home.js";
import settingsRoute from "./routes/settings.js";

// ---------- AUTO‑UPDATE ----------
import { checkForUpdates, downloadAndUpdate } from "../src/updater.js";   // adjust path if needed

const app = express();

app.use(cors());
app.use(express.json());

// Existing routes
app.use("/providers", providersRoute);
app.use("/search", searchRoute);
app.use("/search-all", searchAllRoute);
app.use("/details", detailsRoute);
app.use("/stream", streamRoute);
app.use("/proxy", proxyRoute);
app.use("/home", homeRoute);
app.use("/api/settings", settingsRoute);

// Health check
app.get("/health", (req, res) => res.json({ ok: true, ts: Date.now() }));

// Debug HTML fetch
import { fetchHTML } from "./providers/common.js";
app.get("/debug/fetch", async (req, res) => {
  try {
    const html = await fetchHTML(req.query.url);
    res.send(html);
  } catch (e) {
    res.status(500).send(e.message);
  }
});

// ---------- AUTO‑UPDATE ENDPOINTS ----------
// Check for provider updates
app.get("/api/updates/check", async (req, res) => {
  try {
    const updates = await checkForUpdates();
    res.json({ updates });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Apply provider updates
app.post("/api/updates/apply", async (req, res) => {
  try {
    const { names } = req.body;   // expected: { names: ["anidao", ...] }
    if (!names || !Array.isArray(names)) {
      return res.status(400).json({ error: 'Missing or invalid "names" array' });
    }
    await downloadAndUpdate(names);
    res.json({ success: true });
});

// ---------- HEARTBEAT MONITORING (Auto-Close) ----------
let lastHeartbeat = Date.now();

app.post("/api/heartbeat", (req, res) => {
  lastHeartbeat = Date.now();
  res.json({ success: true });
});

if (process.argv.includes('--autoclose')) {
  console.log('[Heartbeat] Auto-close monitoring active. Server will terminate if client heartbeat is lost.');
  // Wait 15 seconds before starting strict heartbeat enforcement to allow app to fully start
  setTimeout(() => {
    setInterval(() => {
      if (Date.now() - lastHeartbeat > 10000) {
        console.log('[Heartbeat] Lost connection to client. Shutting down Node server...');
        process.exit(0);
      }
    }, 3000);
  }, 15000);
}

export default app;