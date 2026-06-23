import hd4khub from "../providers/4khdhub/index.js";
import anidb from "../providers/anidb/index.js";


const providers = {
    "4khdhub": hd4khub,
    anidb,
};

export function getProvider(name){
    return providers[name];
}

export function getProviders(){
    return Object.keys(providers);
}
