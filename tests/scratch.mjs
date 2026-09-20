// tests/scratch.mjs — every temporary directory a node suite makes, gone
// when the process ends.
//
//   import { scratch } from '../../tests/scratch.mjs';
//   const home = scratch('home-');          // like fs.mkdtempSync under os.tmpdir()
//
// The suites made their directories with fs.mkdtempSync(path.join(
// os.tmpdir(), prefix)) inline, most with no removal, and one run of
// tests/run.sh left about seventy of them under the account's TMPDIR
// (measured 2026-09-20: 472 directories, 120 MB, after two days). The
// owner's rule is that a test run leaves behind nothing it did not find
// (2026-09-19); a removal in each test's own `finally` is the shape that
// was forgotten seventy times, so the registration happens where the
// directory is made and the removal where the process ends, whatever
// ended it. tests/static.sh refuses the inline form in a *.test.mjs.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const made = [];
export function scratch(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  made.push(dir);
  return dir;
}
process.on('exit', () => {
  for (const dir of made) fs.rmSync(dir, { recursive: true, force: true });
});
