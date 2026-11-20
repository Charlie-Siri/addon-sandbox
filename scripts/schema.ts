// Writes docs/usecase.schema.json from src/core/usecase.ts (npm test checks it is current).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { useCaseSchema } from '../src/core/usecase.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = path.join(root, 'docs', 'usecase.schema.json');
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(useCaseSchema(), null, 2) + '\n');
console.log(`Wrote ${path.relative(root, file)}`);
