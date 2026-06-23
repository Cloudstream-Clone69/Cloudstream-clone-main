import express from "express";
import { getProvider } from "../services/providerManager.js";

const router = express.Router();

router.get("/", async (req,res)=>{

    try{

        const provider =
            getProvider(req.query.provider);

        if(!provider){
            return res.status(404).json({
                success:false,
                error:"Provider not found"
            });
        }

        const streams = await provider.getStreams(req.query.url);
        const streamUrl = streams.streamUrl || '';
        const referer = streams.referer || '';

        // Detect stream format and choose the right proxy endpoint
        const isHls  = streamUrl.includes('.m3u8');
        const isDash = streamUrl.includes('.mpd');
        // Extract cookie from response headers if present
        const headers = streams.headers || {};
        const cookie = headers['Cookie'] || headers['cookie'] || '';

        let proxyUrl = '';
        if (streamUrl) {
          if (isDash) {
            // DASH: proxy URL MUST end in .mpd so MPV detects DASH via file extension
            // /proxy/mpd?... has no extension → MPV ignores DASH demuxer → no segments
            // /proxy/stream.mpd?... ends in .mpd → MPV uses DASH demuxer immediately
            const cookieEnc = encodeURIComponent(cookie);
            proxyUrl = `http://127.0.0.1:3000/proxy/stream.mpd?url=${encodeURIComponent(streamUrl)}&ref=${encodeURIComponent(referer)}&cookie=${cookieEnc}`;
          } else if (isHls) {
            proxyUrl = `http://127.0.0.1:3000/proxy/hls?url=${encodeURIComponent(streamUrl)}&ref=${encodeURIComponent(referer)}`;
          } else {
            let filename = 'stream.mkv';
            try {
              const urlPath = new URL(streamUrl).pathname;
              const matches = urlPath.match(/\/([^\/]+\.(?:mkv|mp4|webm|avi|mov|ts|m4v))$/i);
              if (matches) {
                filename = matches[1];
              }
            } catch (_) {}
            proxyUrl = `http://127.0.0.1:3000/proxy/video/${encodeURIComponent(filename)}?url=${encodeURIComponent(streamUrl)}&ref=${encodeURIComponent(referer)}`;
          }
        }

        res.json({
            success:true,
            streams:{
                ...streams,
                proxyUrl
            }
        });

        // ── Background pre-fetch for DASH: warm the MPD raw cache immediately ─
        if (isDash && proxyUrl) {
          setImmediate(async () => {
            try {
              const { default: axios } = await import('axios');
              await axios.get(proxyUrl, { timeout: 25000 });
              console.log('[Stream] DASH MPD pre-fetch complete — cached');
            } catch (_) { /* silent */ }
          });
        }

    }catch(err){

        res.status(500).json({
            success:false,
            error:err.message
        });

    }

});

export default router;
