// Minimal App Store Connect API client (ES256 JWT, no dependencies).
// Reads APPLE_API_KEY_ID, APPLE_API_ISSUER and APPLE_API_KEY_PATH (a .p8 file
// or the directory holding AuthKey_<id>.p8).
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const KID = process.env.APPLE_API_KEY_ID;
const ISS = process.env.APPLE_API_ISSUER;
let keyPath = (process.env.APPLE_API_KEY_PATH || `${process.env.HOME}/.appstoreconnect/private_keys`).replace(/^~/, process.env.HOME);
if (!KID || !ISS) throw new Error('APPLE_API_KEY_ID and APPLE_API_ISSUER must be set');
if (fs.statSync(keyPath).isDirectory()) keyPath = path.join(keyPath, `AuthKey_${KID}.p8`);
const key = fs.readFileSync(keyPath);

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function token() {
  const now = Math.floor(Date.now() / 1000);
  const h = b64({ alg: 'ES256', kid: KID, typ: 'JWT' });
  const p = b64({ iss: ISS, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' });
  const sig = crypto.sign('sha256', Buffer.from(`${h}.${p}`), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${h}.${p}.${sig}`;
}

export async function api(method, urlPath, body) {
  const r = await fetch('https://api.appstoreconnect.apple.com' + urlPath, {
    method,
    headers: { Authorization: 'Bearer ' + token(), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${method} ${urlPath} ${r.status}: ${text.slice(0, 1500)}`);
  return text ? JSON.parse(text) : {};
}
