// Serves the Harness Remote web bundle (extracted from the released Android APK,
// which embeds the identical production PWA) on loopback so it can be reached
// through the tunnel with no third-party origin involved.
//
// Usage: bun serve.ts [--root <dir>] [--port <n>] [--host <addr>]

const args = process.argv.slice(2);
const arg = (name: string, fallback: string): string => {
  const i = args.indexOf(`--${name}`);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
};

const root = arg("root", `${import.meta.dir}/dist`).replace(/\/+$/, "");
const port = Number(arg("port", "5173"));
const host = arg("host", "127.0.0.1");

const MIME: Record<string, string> = {
  html: "text/html; charset=utf-8",
  js: "text/javascript; charset=utf-8",
  mjs: "text/javascript; charset=utf-8",
  css: "text/css; charset=utf-8",
  json: "application/json; charset=utf-8",
  webmanifest: "application/manifest+json; charset=utf-8",
  svg: "image/svg+xml",
  png: "image/png",
  ico: "image/x-icon",
  aac: "audio/aac",
  woff2: "font/woff2",
};

const contentType = (path: string): string => {
  const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  return MIME[ext] ?? "application/octet-stream";
};

const server = Bun.serve({
  hostname: host,
  port,
  async fetch(req) {
    const url = new URL(req.url);
    let rel = decodeURIComponent(url.pathname);
    if (rel.endsWith("/")) rel += "index.html";
    // Reject traversal before touching the filesystem.
    if (rel.split("/").includes("..")) return new Response("bad path", { status: 400 });

    const target = Bun.file(`${root}${rel}`);
    if (await target.exists()) {
      return new Response(target, { headers: { "content-type": contentType(rel) } });
    }
    // SPA fallback: unknown deep links render the app shell.
    return new Response(Bun.file(`${root}/index.html`), {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
});

console.log(`harness-remote web bundle on http://${host}:${port} (root: ${root})`);
void server;
