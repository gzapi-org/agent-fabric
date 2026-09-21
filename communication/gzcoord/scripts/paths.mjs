// Where this runtime's agent-fabric checkout is, and nothing else.
//
// It lives alone because two modules need it and neither may import the
// other: i18n.mjs holds the dictionaries, gzmsg.mjs holds the validator
// whose diagnostics are dictionary lines, and an import in both
// directions is a cycle. A third module that imports nothing is the
// cheapest way to have one definition instead of two — the duplicate
// being exactly the drift this branch spent two review rounds removing
// elsewhere.
//
// gzmsg.mjs re-exports FABRIC_ROOT, so every existing importer of it
// keeps working and nothing outside this directory changes.
import { fileURLToPath } from 'node:url';

// fileURLToPath, not URL.pathname: .pathname keeps the percent-encoding
// of a checkout path with a space in it and names a file nothing has.
export const FABRIC_ROOT =
  process.env.AGENT_FABRIC_ROOT ?? fileURLToPath(new URL('../../../', import.meta.url)).replace(/\/$/, '');
