// SPDX-License-Identifier: MIT
// Development only: record the original Pele engine's geometry and text.
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';

const context = vm.createContext({});
vm.runInContext(fs.readFileSync('vendor/pele/pele.global.js', 'utf8'), context);
const digest = values => crypto.createHash('sha256').update(values.join('\0')).digest('hex');
const options = {fontSize: 16, fontFamily: 'sans-serif', autoDirection: false,
  images: false, links: false, responsive: false, now: Date.UTC(2026, 0, 1)};
const files = {};
let count = 0;
for (const file of fs.readdirSync('test/corpus').filter(name => name.endsWith('-docs.json')).sort()) {
  files[file] = JSON.parse(fs.readFileSync(`test/corpus/${file}`, 'utf8')).map(source => {
    count++;
    try {
      const result = context.pele.render(source, options);
      return {ok: true, width: result.width, height: result.height, type: result.type,
        paths: digest([...result.svg.matchAll(/<path\b[^>]*\bd="([^"]*)"/g)].map(match => match[1])),
        text: digest([...result.svg.matchAll(/>([^<]*)</g)].map(match => match[1]).filter(Boolean))};
    } catch (error) {
      return {ok: false, code: error.code, message: error.message};
    }
  });
}
fs.writeFileSync('test/corpus/manifest.json', JSON.stringify({pele: '1.13.0', now: options.now, files}, null, 2) + '\n');
console.log(`${count} cases across ${Object.keys(files).length} diagram types`);
