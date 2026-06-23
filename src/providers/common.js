import { wrapper } from 'axios-cookiejar-support';
import { CookieJar } from 'tough-cookie';
import https from 'https';
import http from 'http';
import { createAxios } from '../services/dnsAxios.js';

// Global agents use DoH via dnsAxios interceptors; no override needed here.

const jar = new CookieJar();

const client = wrapper(createAxios({
  timeout: 30000,
  headers: {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.5',
    'Accept-Encoding': 'gzip, deflate, br',
    'Connection': 'keep-alive',
  },
  jar,
  maxRedirects: 10,
  decompress: true,
}));

export async function fetchHTML(url, referer = null, retries = 2, timeout = 30000) {
  const headers = referer ? { Referer: referer } : {};
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      console.log(`  [fetch] ${url}`);
      const response = await client.get(url, { headers, timeout });
      return response.data;
    } catch (error) {
      console.error(`  [fetch] attempt ${attempt} failed: ${error.message}`);
      if (attempt === retries) throw error;
      await new Promise(r => setTimeout(r, 3000 * attempt));
    }
  }
}

export async function fetchHTMLPost(url, data, referer = null, retries = 2, timeout = 15000) {
  const headers = referer ? { Referer: referer } : {};
  headers['Content-Type'] = 'application/x-www-form-urlencoded';
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      console.log(`  [fetch POST] ${url}`);
      const response = await client.post(url, data, { headers, timeout });
      return response.data;
    } catch (error) {
      console.error(`  [fetch POST] attempt ${attempt} failed: ${error.message}`);
      if (attempt === retries) throw error;
      await new Promise(r => setTimeout(r, 3000 * attempt));
    }
  }
}

export async function fetchJSON(url, referer = null, origin = null, retries = 2, timeout = 15000) {
  const headers = {};
  if (referer) headers['Referer'] = referer;
  if (origin) headers['Origin'] = origin;
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      console.log(`  [fetch] ${url}`);
      const response = await client.get(url, { headers, timeout });
      return JSON.parse(response.data);
    } catch (error) {
      console.error(`  [fetch] attempt ${attempt} failed: ${error.message}`);
      if (attempt === retries) throw error;
      await new Promise(r => setTimeout(r, 3000 * attempt));
    }
  }
}

export async function headRequest(url, referer = null, timeout = 15000) {
  const headers = referer ? { Referer: referer } : {};
  try {
    const response = await client.head(url, { headers, timeout });
    return response.headers;
  } catch (error) {
    return null;
  }
}

export async function resolveFinalUrl(url, referer = null) {
  const headers = referer ? { Referer: referer } : {};
  try {
    const response = await client.head(url, { headers, maxRedirects: 10 });
    return response.request.res.responseUrl || url;
  } catch (error) {
    try {
      const getResp = await client.get(url, {
        headers: { ...headers, Range: 'bytes=0-0' },
        maxRedirects: 10,
        timeout: 10000,
        responseType: 'stream',
      });
      try {
        getResp.data.destroy();
      } catch (_) {}
      return getResp.request.res.responseUrl || url;
    } catch (getError) {
      return url;
    }
  }
}
