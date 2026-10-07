'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { randomUUID } = require('crypto');

function artifactUrl(pdfUrl) {
  const url = new URL(pdfUrl);
  if (!url.pathname.endsWith('/output.pdf')) throw new Error('Cannot locate the SyncTeX output');
  url.pathname = url.pathname.slice(0, -'output.pdf'.length) + 'output.synctex.gz';
  // Keep compileGroup, build, and worker routing parameters intact.
  return url.toString();
}

function sidecars(pdfPath) {
  if (!path.isAbsolute(pdfPath) || !pdfPath.endsWith('.pdf')) throw new Error('Expected an absolute PDF path');
  return [pdfPath.slice(0, -4) + '.synctex', pdfPath.slice(0, -4) + '.synctex.gz'];
}

function remove(file) {
  try { fs.unlinkSync(file); } catch (err) { if (err.code !== 'ENOENT') throw err; }
}

async function download(params, downloadUrl) {
  const targets = sidecars(params.pdfPath);
  let stage;
  try {
    const result = await downloadUrl({
      cookie: params.cookie,
      url: params.url || artifactUrl(params.pdfUrl),
      outputDir: path.dirname(params.pdfPath),
      fileName: 'synctex-' + randomUUID(),
    });
    stage = result.path;
    const data = fs.readFileSync(stage);
    const compressed = data[0] === 0x1f && data[1] === 0x8b;
    const plain = compressed ? zlib.gunzipSync(data, { maxOutputLength: 64 * 1024 * 1024 }) : data;
    if (plain.length > 64 * 1024 * 1024) throw new Error('SyncTeX output is too large');
    const text = plain.toString('utf8');
    if (!/^SyncTeX Version:\d+\r?\n/.test(text) || !/^Content:\r?$/m.test(text)) {
      throw new Error('Downloaded output is not a SyncTeX map');
    }
    const inputs = [...text.matchAll(/^Input:\d+:(.+)\r?$/gm)].map(match => match[1].replace(/\r$/, ''));
    if (!inputs.length) throw new Error('SyncTeX map contains no source files');
    const target = targets[compressed ? 1 : 0];
    // Preserve the bytes: rewriting Input records breaks SyncTeX byte offsets.
    fs.renameSync(stage, target);
    stage = null;
    remove(targets[compressed ? 0 : 1]);
    return { path: target, inputs };
  } catch (err) {
    // Never let the previous compile's map direct clicks on a new PDF.
    for (const target of targets) remove(target);
    throw err;
  } finally {
    if (stage) remove(stage);
  }
}

module.exports = { artifactUrl, download };
