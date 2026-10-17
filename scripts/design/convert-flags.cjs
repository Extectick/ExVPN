// SPDX-License-Identifier: Apache-2.0
// Converts the pinned flag-icons 4:3 sources; never fetches runtime assets.
// Usage: node convert-flags.cjs <upstream-directory> <sharp-module-directory>
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require(process.argv[3]);
(async () => {
  const source = path.resolve(process.argv[2]);
  const destination = path.resolve(__dirname, '../../apps/exvpn/assets/flags');
  const flags = (await fs.readdir(path.join(source, 'flags/4x3')))
    .filter(file => /^[a-z]{2}\.svg$/.test(file)).sort();
  for (const flag of flags) {
    await sharp(path.join(source, 'flags/4x3', flag), {density: 192})
      .resize(160, 120, {fit: 'contain', background: '#00000000'})
      .png().toFile(path.join(destination, flag.replace('.svg', '.png')));
  }
  await fs.copyFile(path.join(source, 'LICENSE'),
    path.resolve(__dirname, '../../apps/exvpn/assets/licenses/FlagIcons.txt'));
  const codes = flags.map(file => file.slice(0,2)).join(' ');
  await fs.writeFile(path.join(destination, 'countries.txt'), codes + '\n');
  process.stdout.write(`Converted ${flags.length} flags at 160x120.\n`);
})();
