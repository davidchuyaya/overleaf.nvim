'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { spawnSync } = require('child_process');
const synctex = require('../../node/synctex');
const inverse = require('../../node/inverse-search');

const map = Buffer.from('SyncTeX Version:1\nInput:1:/compile/main.tex\nInput:2:./chapters/intro.tex\nContent:\n!123\n{1\n}\nPostamble:\nCount:1\n');

test('derived map URL keeps the exact build and worker routing', () => {
  assert.equal(synctex.artifactUrl('https://worker.test/project/id/build/abc/output/output.pdf?compileGroup=standard&clsiserverid=xyz'),
    'https://worker.test/project/id/build/abc/output/output.synctex.gz?compileGroup=standard&clsiserverid=xyz');
  assert.throws(() => synctex.artifactUrl('https://worker.test/other.pdf'), /Cannot locate/);
});

for (const compressed of [false, true]) {
  test(`installs ${compressed ? 'compressed' : 'plain'} map beside PDF without rewriting offsets`, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'overleaf-synctex-test-'));
    try {
      const pdfPath = path.join(dir, 'Project with spaces.pdf');
      const data = compressed ? zlib.gzipSync(map) : map;
      const other = path.join(dir, 'Project with spaces.synctex' + (compressed ? '' : '.gz'));
      fs.writeFileSync(other, 'old map');
      let staged;
      const result = await synctex.download({ pdfPath, cookie: 'fixture', pdfUrl: 'https://test/output.pdf?build=abc' }, async params => {
        assert.equal(params.cookie, 'fixture');
        assert.equal(params.url, 'https://test/output.synctex.gz?build=abc');
        assert.equal(params.outputDir, dir);
        staged = path.join(dir, params.fileName);
        fs.writeFileSync(staged, data);
        return { path: staged };
      });
      assert.equal(result.path, path.join(dir, 'Project with spaces.synctex' + (compressed ? '.gz' : '')));
      assert.deepEqual(fs.readFileSync(result.path), data);
      assert.deepEqual(result.inputs, ['/compile/main.tex', './chapters/intro.tex']);
      assert.equal(fs.existsSync(other), false);
      assert.equal(fs.existsSync(staged), false);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
}

for (const data of [Buffer.from('<html>please log in</html>'), Buffer.from([0x1f, 0x8b, 0]), Buffer.from('SyncTeX Version:1\nContent:\n')]) {
  test('failed/invalid map removes stale sidecars and staging files', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'overleaf-synctex-test-'));
    try {
      const pdfPath = path.join(dir, 'doc.pdf');
      for (const suffix of ['.synctex', '.synctex.gz']) fs.writeFileSync(path.join(dir, 'doc' + suffix), 'stale');
      await assert.rejects(synctex.download({ pdfPath, url: 'https://test/exact-map' }, async params => {
        assert.equal(params.url, 'https://test/exact-map');
        const stage = path.join(dir, params.fileName);
        fs.writeFileSync(stage, data);
        return { path: stage };
      }));
      assert.deepEqual(fs.readdirSync(dir), []);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
}

test('network failure clears the previous map without touching the PDF', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'overleaf-synctex-test-'));
  try {
    const pdfPath = path.join(dir, 'doc.pdf');
    fs.writeFileSync(pdfPath, 'fixture PDF');
    fs.writeFileSync(path.join(dir, 'doc.synctex.gz'), 'stale');
    await assert.rejects(synctex.download({ pdfPath, pdfUrl: 'https://test/output.pdf' }, async () => {
      throw new Error('HTTP 404');
    }), /HTTP 404/);
    assert.deepEqual(fs.readdirSync(dir), ['doc.pdf']);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

function args(file = '/compile/main.tex', line = '20', column = '3') {
  const context = { project: 'project-a', instance: 'https://www.overleaf.com', connection: 1, pdf: '/tmp/My PDF.pdf' };
  return ['/absolute/nvim', '/tmp/editor socket', Buffer.from(JSON.stringify(context)).toString('hex'), file, line, column];
}

test('callback launches only the specified Neovim RPC client without a shell', () => {
  inverse.run(args("/compile/O'Brien chapter.tex"), (exe, argv, opts) => {
    assert.equal(exe, '/absolute/nvim');
    assert.deepEqual(argv.slice(0, 3), ['--server', '/tmp/editor socket', '--remote-expr']);
    assert.equal(argv[3], inverse.expression(args("/compile/O'Brien chapter.tex")));
    assert.equal(opts.shell, undefined);
    assert.equal(opts.timeout, 10000);
    return { status: 0, stdout: '1\n' };
  });
});

test('filenames remain literal data through actual Neovim expression evaluation', () => {
  const file = "/compile/O'Brien α $(touch /tmp/NEVER) \\ quotes\".tex";
  const result = spawnSync('nvim', ['--headless', '-u', 'NONE', '-i', 'NONE',
    '--cmd', "lua package.preload['overleaf.inverse_search'] = function() return { receive = function(r) vim.g.inverse_request = r; return 1 end } end",
    '--cmd', 'lua local accepted = vim.fn.eval(vim.env.OVERLEAF_TEST_EXPR); io.stdout:write(vim.json.encode({accepted = accepted, request = vim.g.inverse_request}))',
    '-c', 'qa!'], {
    encoding: 'utf8', timeout: 10000,
    env: { ...process.env, OVERLEAF_TEST_EXPR: inverse.expression(args(file, '42', '-1')) },
  });
  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout.trim());
  assert.equal(parsed.accepted, 1);
  assert.equal(parsed.request.file, file);
  assert.equal(parsed.request.line, 42);
  assert.equal(parsed.request.column, 0);
});

test('rejects malformed locations and handles a disconnected Neovim', () => {
  for (const bad of [args('main.tex', '0'), args('main.tex', '1 | quit'), args('main\n.tex'), args('main.tex', '1', 'NaN'), [...args(), 'extra']]) {
    assert.throws(() => inverse.expression(bad));
  }
  const badContext = args();
  badContext[2] = 'bad';
  assert.throws(() => inverse.expression(badContext));
  assert.throws(() => inverse.run(args(), () => ({ status: 0, stdout: '0\n' })), /no longer connected/);
  assert.throws(() => inverse.run(args(), () => ({ error: new Error('socket closed') })), /socket closed/);
});
