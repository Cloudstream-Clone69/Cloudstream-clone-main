import axios from 'axios';

const cdnUrl = 'https://patient-cloud-109a.gicosab429.workers.dev/8b7c00c82edd1c5efd3ad64782266586f2a58725c6d221f68d0a667a9254a8f78e0fc83371b966b7dd1bdee700f93ebf::64541e96fc4d6376bc2db08c1483703f/1397982780/Spider-Man%20-%20Into%20the%20Spider-Verse%20(2018)%201080p%20BluRay%20x264%20AVC%20%5BOrg%20UHD%20Hindi%20BD%205.1%20~%20640Kbps%20+%20DTS-HDMA%205.1%20English%5D%20ESubs%20~%20WiKi-4kHdHub.mkv';
const referer = 'https://gamerxyt.com/hubcloud.php?host=hubcloud&id=ids1vnmtspvwscm&token=eGZXeEhvemc3c3JibFIweGdQRzVpTURsMDlqQ2VsY0dTckhsMDY2VmtaND0=';

async function testWithReferer(ref) {
  try {
    console.log(`\nTesting with Referer: "${ref}"`);
    const res = await axios.get(cdnUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': ref,
        'Origin': new URL(ref).origin,
        Range: 'bytes=0-100'
      },
      maxRedirects: 10
    });
    console.log("SUCCESS! status:", res.status);
    console.log("headers:", res.headers);
  } catch (err) {
    console.error("FAILED! error:", err.message);
  }
}

async function run() {
  await testWithReferer(referer);
  await testWithReferer('https://gamerxyt.com/');
  await testWithReferer('https://hubcloud.foo/');
}

run();
