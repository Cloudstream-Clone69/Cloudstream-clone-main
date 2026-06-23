import express from "express";
import { getProvider } from "../services/providerManager.js";

const router = express.Router();

router.get("/", async (req,res)=>{

    try{

        const provider = getProvider(req.query.provider);

        if(!provider){
            return res.status(404).json({
                success:false,
                error:"Provider not found"
            });
        }

        const results = await provider.search(req.query.q);

        res.json({
            success:true,
            results
        });

    }catch(err){

        res.status(500).json({
            success:false,
            error:err.message
        });

    }

});

export default router;
