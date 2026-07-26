import { chmodSync, copyFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('./atomic_swap.py', import.meta.url));
const destination = fileURLToPath(new URL('../dist/atomic_swap.py', import.meta.url));

copyFileSync(source, destination);
chmodSync(destination, 0o755);
