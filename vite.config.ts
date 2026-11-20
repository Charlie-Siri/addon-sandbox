import { defineConfig } from 'vite';
import { sandboxServer } from './server/plugin.ts';

export default defineConfig({
  plugins: [sandboxServer()],
  server: { port: 5199, strictPort: true, host: '127.0.0.1' },
});
