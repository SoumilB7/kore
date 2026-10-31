import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// The relay's tests run inside the Workers runtime (Miniflare), offline.
export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.toml" } })],
  server: { fs: { allow: [".", "../protocol/fixtures/relay"] } },
});
