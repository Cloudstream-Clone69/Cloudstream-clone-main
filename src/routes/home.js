import express from "express";
import { getProvider } from "../services/providerManager.js";

const router = express.Router();

// Curated keyword sets for each carousel section
const HOME_QUERIES = [
  { section: "Top Movies",    provider: "4khdhub", queries: ["avengers", "batman", "spider-man"] },
  { section: "Top Series",    provider: "4khdhub", queries: ["the boys", "breaking bad", "game of thrones"] },
  { section: "Top Anime",     provider: "anidb",  queries: ["one piece", "dragon ball", "naruto"] },
  { section: "Top Airing Anime", provider: "anidb", queries: ["attack on titan", "demon slayer", "my hero academia"] },
];

router.get("/", async (req, res) => {
  try {
    const sections = await Promise.all(
      HOME_QUERIES.map(async ({ section, provider, queries }) => {
        try {
          const p = getProvider(provider);
          // Run all queries for this section in parallel, merge & dedupe by url
          const all = await Promise.all(
            queries.map(q => p.search(q).catch(() => []))
          );
          const seen = new Set();
          const results = [];
          for (const batch of all) {
            for (const item of batch) {
              if (!seen.has(item.url)) {
                seen.add(item.url);
                results.push({ ...item, provider });
              }
            }
          }
          return { section, provider, results: results.slice(0, 20) };
        } catch {
          return { section, provider, results: [] };
        }
      })
    );

    res.json({ success: true, sections });
  } catch (err) {
    res.status(500).json({ success: false, error: err.message });
  }
});

export default router;
