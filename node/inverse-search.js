#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');

function expression(args) {
  if (args.length !== 6) throw new Error('Expected Neovim, server, context, file, line, column');
  const [, , encoded, file, line, column] = args;
  if (!/^(?:[0-9a-f]{2})+$/.test(encoded)) throw new Error('Invalid inverse-search context');
  const context = JSON.parse(Buffer.from(encoded, 'hex').toString('utf8'));
  if (typeof context.project !== 'string' || typeof context.pdf !== 'string' ||
      typeof context.instance !== 'string' || !Number.isSafeInteger(context.connection)) {
    throw new Error('Invalid inverse-search context');
  }
  if (!file || /[\0\r\n]/.test(file) || !/^\d+$/.test(line) || !/^-?\d+$/.test(column) ||
      !Number.isSafeInteger(Number(line)) || Number(line) < 1 || !Number.isSafeInteger(Number(column))) {
    throw new Error('Invalid source location');
  }
  const request = { context, file, line: Number(line), column: Math.max(0, Number(column)) };
  // A Vim single-quoted literal, decoded as JSON, keeps filenames strictly data.
  const literal = JSON.stringify(request).replace(/'/g, "''");
  return `luaeval("require('overleaf.inverse_search').receive(_A)", json_decode('${literal}'))`;
}

function run(args, spawn = spawnSync) {
  const expr = expression(args);
  const result = spawn(args[0], ['--server', args[1], '--remote-expr', expr], {
    encoding: 'utf8', timeout: 10000, windowsHide: true,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || 'Could not contact Neovim');
  if (result.stdout.trim() !== '1') throw new Error('PDF is no longer connected to this Overleaf project');
}

if (require.main === module) {
  try { run(process.argv.slice(2)); } catch (err) {
    console.error('[overleaf inverse search] ' + err.message);
    process.exitCode = 1;
  }
}

module.exports = { expression, run };
