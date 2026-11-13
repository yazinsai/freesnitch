// Registers the fork's bundle IDs, enables the capabilities FreeSnitch needs,
// and (re)creates the two Developer ID provisioning profiles.
//
//   node Scripts/fork/profiles.mjs <bundle-prefix> <out-dir>
//
// Writes <out-dir>/app.provisionprofile and <out-dir>/netext.provisionprofile.
import { api } from './asc.mjs';
import fs from 'node:fs';
import { execSync } from 'node:child_process';

const [prefix, outDir] = process.argv.slice(2);
if (!prefix || !outDir) { console.error('usage: profiles.mjs <bundle-prefix> <out-dir>'); process.exit(2); }

// The Developer ID certificate whose private key is in this keychain.
const serial = execSync(`security find-certificate -c "Developer ID Application" -p | openssl x509 -noout -serial`)
  .toString().trim().replace(/^serial=/, '').toUpperCase();
const certs = (await api('GET', '/v1/certificates?limit=200')).data;
const cert = certs.find((c) => c.attributes.serialNumber.toUpperCase() === serial);
if (!cert) throw new Error(`no App Store Connect certificate matches keychain serial ${serial}`);

async function bundle(identifier, name, caps) {
  const found = await api('GET', `/v1/bundleIds?filter[identifier]=${identifier}&filter[platform]=MAC_OS`);
  let b = found.data.find((x) => x.attributes.identifier === identifier);
  if (!b) {
    b = (await api('POST', '/v1/bundleIds', { data: { type: 'bundleIds', attributes: { identifier, name, platform: 'MAC_OS' } } })).data;
    console.log('registered', identifier);
  }
  const have = (await api('GET', `/v1/bundleIds/${b.id}/bundleIdCapabilities`)).data.map((c) => c.attributes.capabilityType);
  for (const cap of caps.filter((c) => !have.includes(c))) {
    await api('POST', '/v1/bundleIdCapabilities', {
      data: { type: 'bundleIdCapabilities', attributes: { capabilityType: cap },
              relationships: { bundleId: { data: { type: 'bundleIds', id: b.id } } } },
    });
    console.log(' enabled', cap, 'on', identifier);
  }
  return b;
}

async function profile(b, name, file) {
  for (const p of (await api('GET', `/v1/profiles?filter[name]=${encodeURIComponent(name)}`)).data) {
    await api('DELETE', `/v1/profiles/${p.id}`);
  }
  const p = (await api('POST', '/v1/profiles', {
    data: { type: 'profiles', attributes: { name, profileType: 'MAC_APP_DIRECT' },
            relationships: { bundleId: { data: { type: 'bundleIds', id: b.id } },
                             certificates: { data: [{ type: 'certificates', id: cert.id }] } } },
  })).data;
  fs.writeFileSync(file, Buffer.from(p.attributes.profileContent, 'base64'));
  console.log('profile', name, '->', file);
}

fs.mkdirSync(outDir, { recursive: true });
const app = await bundle(prefix, 'FreeSnitch', ['NETWORK_EXTENSIONS', 'SYSTEM_EXTENSION_INSTALL']);
const ext = await bundle(`${prefix}.netext`, 'FreeSnitch NetExt', ['NETWORK_EXTENSIONS']);
await profile(app, `FreeSnitch Fork App DeveloperID`, `${outDir}/app.provisionprofile`);
await profile(ext, `FreeSnitch Fork NetExt DeveloperID`, `${outDir}/netext.provisionprofile`);
