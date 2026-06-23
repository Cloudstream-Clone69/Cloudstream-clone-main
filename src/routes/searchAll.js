import express from "express";
import { getProvider, getProviders } from "../services/providerManager.js";
import fs from 'fs';
import path from 'path';

const router = express.Router();

function loadSettings() {
  try {
    const SETTINGS_PATH = path.join(process.cwd(), 'app-settings.json');
    if (fs.existsSync(SETTINGS_PATH)) {
      return JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
    }
  } catch (_) {}
  return {};
}

router.get("/", async (req,res)=>{

    try{

        const q = req.query.q;

        const settings = loadSettings();
        const enabledMap = settings.providers || {};
        const allProviders = getProviders();
        const providers = allProviders.filter(name => enabledMap[name] !== false);

        const sections = await Promise.all(

            providers.map(async(name)=>{

                try{

                    const provider =
                        getProvider(name);

                    const results =
                        await provider.search(q);

                    return {
                        provider:name,
                        results
                    };

                }catch{

                    return {
                        provider:name,
                        results:[]
                    };

                }

            })

        );

        res.json({
            success:true,
            sections
        });

    }catch(err){

        res.status(500).json({
            success:false,
            error:err.message
        });

    }

});

export default router;
