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
const removeAll = () => { for (const dir of made.splice(0)) fs.rmSync(dir, { recursive: true, force: true }); };
process.on('exit', removeAll);
// A signal's default action ends the process WITHOUT the exit event — an
// interrupted or timed-out run is exactly the run that leaves the most
// behind. Handling the signal ourselves: remove, then end with the
// conventional 128+signal status so the runner still sees a killed
// process. Only one handler per signal: installing ours removes Node's
// default, and nothing else in a suite process wants these.
for (const [sig, num] of [['SIGINT', 2], ['SIGTERM', 15], ['SIGHUP', 1]]) {
  process.on(sig, () => { removeAll(); process.exit(128 + num); });
}
