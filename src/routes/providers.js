import express from "express";
import { getProviders } from "../services/providerManager.js";

const router = express.Router();

router.get("/", (req,res)=>{
    res.json({
        success:true,
        providers:getProviders()
    });
});

export default router;
