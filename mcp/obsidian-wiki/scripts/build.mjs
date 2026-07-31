import { chmodSync, copyFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('./atomic_swap.py', import.meta.url));
const destination = fileURLToPath(new URL('../dist/atomic_swap.py', import.meta.url));

copyFileSync(source, destination);
chmodSync(destination, 0o755);

for (const name of ['wiki_candidate_journal.py', 'wiki_session_state.py']) {
  const scriptSource = fileURLToPath(new URL(`../../../scripts/${name}`, import.meta.url));
  const scriptDestination = fileURLToPath(new URL(`../dist/${name}`, import.meta.url));
  copyFileSync(scriptSource, scriptDestination);
  chmodSync(scriptDestination, 0o755);
}
