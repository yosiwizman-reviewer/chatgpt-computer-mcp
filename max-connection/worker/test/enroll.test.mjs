// Run: node --test max-connection/worker/test/   (Node 22.5+ for node:sqlite)
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import { createHash, randomBytes } from "node:crypto";
import worker from "../src/index.js";

const schema = readFileSync(new URL("../schema.sql", import.meta.url), "utf8");

// Minimal D1 shim over node:sqlite (D1 uses ?1-style params, as does SQLite).
function d1(db) {
  return {
    prepare(sql) {
      const stmt = db.prepare(sql);
      let args = [];
      const api = {
        bind(...a) { args = a; return api; },
        first() { return Promise.resolve(stmt.get(...args) ?? null); },
        all() { return Promise.resolve({ results: stmt.all(...args) }); },
        run() { stmt.run(...args); return Promise.resolve({ success: true }); },
      };
      return api;
    },
  };
}

// Fake Cloudflare API: records tunnels, configs and DNS records.
let cfState;
function installFakeCloudflare() {
  cfState = { tunnels: new Map(), configs: new Map(), dns: [], calls: [] };
  globalThis.fetch = async (url, init) => {
    const u = new URL(url);
    const path = u.pathname.replace("/client/v4", "");
    const method = init.method;
    cfState.calls.push(`${method} ${path}`);
    assert.equal(init.headers.authorization, "Bearer test-token");
    const ok = (result) => new Response(JSON.stringify({ success: true, result }), { status: 200 });
    if (method === "POST" && path.endsWith("/cfd_tunnel")) {
      const id = randomBytes(16).toString("hex").replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, "$1-$2-$3-$4-$5");
      cfState.tunnels.set(id, JSON.parse(init.body).name);
      return ok({ id });
    }
    let m;
    if (method === "PUT" && (m = path.match(/cfd_tunnel\/([^/]+)\/configurations$/))) {
      cfState.configs.set(m[1], JSON.parse(init.body).config);
      return ok({});
    }
    if (method === "GET" && (m = path.match(/cfd_tunnel\/([^/]+)\/token$/))) return ok(`token-for-${m[1]}`);
    if (method === "GET" && path.endsWith("/dns_records")) {
      const name = u.searchParams.get("name");
      return ok(cfState.dns.filter((r) => r.name === name));
    }
    if (method === "POST" && path.endsWith("/dns_records")) {
      cfState.dns.push(JSON.parse(init.body));
      return ok({});
    }
    return new Response(JSON.stringify({ success: false, errors: [{ code: 1 }] }), { status: 404 });
  };
}

let env;
const sha = (s) => createHash("sha256").update(s).digest("hex");
const b64 = (n) => randomBytes(n).toString("base64url");

function addInvite(code, { expiresIn = 3600, state = "new" } = {}) {
  const now = Math.floor(Date.now() / 1000);
  env._db.prepare("INSERT INTO invites (code_hash, created_at, expires_at, state) VALUES (?, ?, ?, ?)")
    .run(sha(code), now, now + expiresIn, state);
}

function enroll(body, ip = "203.0.113.5") {
  return worker.fetch(new Request("https://enroll.akior.io/v1/enroll", {
    method: "POST", headers: { "cf-connecting-ip": ip, "content-type": "application/json" }, body: JSON.stringify(body),
  }), env).then(async (r) => ({ status: r.status, body: await r.json() }));
}

function machine(name = "Office Mac") {
  return { machine_secret: b64(32), machine_id: crypto.randomUUID(), name, os: "darwin", arch: "arm64", port: 51234 };
}

beforeEach(() => {
  const db = new DatabaseSync(":memory:");
  db.exec(schema);
  env = {
    _db: db, DB: d1(db), CF_API_TOKEN: "test-token", CF_ACCOUNT_ID: "acct", CF_ZONE_ID: "zone",
    ZONE_NAME: "akior.io", RESERVED_NAMES: "mc-node-g,mc-admin",
  };
  installFakeCloudflare();
});

test("valid code creates exactly one tunnel, DNS name and ingress", async () => {
  const code = b64(32); addInvite(code);
  const m = machine();
  const r = await enroll({ code, ...m });
  assert.equal(r.status, 200);
  assert.equal(r.body.hostname, "mc-office-mac.akior.io");
  assert.equal(cfState.tunnels.size, 1);
  assert.equal(cfState.dns.length, 1);
  assert.equal(cfState.dns[0].content, `${r.body.tunnel_id}.cfargotunnel.com`);
  const ing = cfState.configs.get(r.body.tunnel_id).ingress[0];
  assert.deepEqual([ing.hostname, ing.path, ing.service, ing.originRequest.httpHostHeader],
    ["mc-office-mac.akior.io", "^/mcp/", "http://localhost:51234", "127.0.0.1:51234"]);
  assert.equal(r.body.tunnel_token, `token-for-${r.body.tunnel_id}`);
  // Nothing account-wide comes back to the machine.
  assert.ok(!JSON.stringify(r.body).includes("test-token"));
});

test("random or unknown code is rejected and creates nothing", async () => {
  const r = await enroll({ code: b64(32), ...machine() });
  assert.equal(r.status, 403);
  assert.equal(cfState.tunnels.size, 0);
});

test("reused code from another machine is rejected", async () => {
  const code = b64(32); addInvite(code);
  assert.equal((await enroll({ code, ...machine("A") })).status, 200);
  const r = await enroll({ code, ...machine("B") });
  assert.equal(r.status, 403);
  assert.equal(cfState.tunnels.size, 1);
});

test("expired and revoked codes are rejected", async () => {
  const c1 = b64(32); addInvite(c1, { expiresIn: -1 });
  const c2 = b64(32); addInvite(c2, { state: "revoked" });
  assert.equal((await enroll({ code: c1, ...machine() })).status, 403);
  assert.equal((await enroll({ code: c2, ...machine() })).status, 403);
  assert.equal(cfState.tunnels.size, 0);
});

test("same machine retrying the same code gets the same tunnel (interrupted install)", async () => {
  const code = b64(32); addInvite(code);
  const m = machine();
  const a = await enroll({ code, ...m });
  const b = await enroll({ code, ...m });
  assert.equal(b.status, 200);
  assert.equal(a.body.tunnel_id, b.body.tunnel_id);
  assert.equal(cfState.tunnels.size, 1);
  assert.equal(cfState.dns.length, 1);
});

test("retry after a crash between tunnel creation and DNS resumes without a second tunnel", async () => {
  const code = b64(32); addInvite(code);
  const m = machine();
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    if (init.method === "POST" && String(url).endsWith("/dns_records")) throw new Error("network down");
    return realFetch(url, init);
  };
  assert.equal((await enroll({ code, ...m })).status, 500);
  globalThis.fetch = realFetch;
  const r = await enroll({ code, ...m });
  assert.equal(r.status, 200);
  assert.equal(cfState.tunnels.size, 1);
  assert.equal(cfState.dns.length, 1);
});

test("same machine reinstalling with a new code keeps its hostname and tunnel", async () => {
  const m = machine();
  const c1 = b64(32); addInvite(c1);
  const c2 = b64(32); addInvite(c2);
  const a = await enroll({ code: c1, ...m });
  const b = await enroll({ code: c2, ...m, port: 52000 });
  assert.equal(a.body.hostname, b.body.hostname);
  assert.equal(cfState.tunnels.size, 1);
  assert.equal(cfState.configs.get(b.body.tunnel_id).ingress[0].service, "http://localhost:52000");
});

test("two machines get independent tunnels, hostnames and tokens", async () => {
  const c1 = b64(32); addInvite(c1);
  const c2 = b64(32); addInvite(c2);
  const a = await enroll({ code: c1, ...machine("Lab PC") });
  const b = await enroll({ code: c2, ...machine("Lab PC") });
  assert.notEqual(a.body.hostname, b.body.hostname);
  assert.equal(b.body.hostname, "mc-lab-pc-2.akior.io");
  assert.notEqual(a.body.tunnel_id, b.body.tunnel_id);
  assert.notEqual(a.body.tunnel_token, b.body.tunnel_token);
});

test("reserved names and names already in DNS are never taken", async () => {
  cfState.dns.push({ name: "mc-shop.akior.io", type: "A", content: "192.0.2.1" });
  const c1 = b64(32); addInvite(c1);
  const c2 = b64(32); addInvite(c2);
  assert.equal((await enroll({ code: c1, ...machine("Node G") })).body.hostname, "mc-node-g-2.akior.io");
  assert.equal((await enroll({ code: c2, ...machine("Shop") })).body.hostname, "mc-shop-2.akior.io");
});

test("update-port needs the machine secret", async () => {
  const code = b64(32); addInvite(code);
  const m = machine();
  const a = await enroll({ code, ...m });
  const post = (body) => worker.fetch(new Request("https://x/v1/update-port", { method: "POST", body: JSON.stringify(body) }), env);
  assert.equal((await post({ machine_secret: b64(32), port: 50000 })).status, 403);
  assert.equal((await post({ machine_secret: m.machine_secret, port: 50000 })).status, 200);
  assert.equal(cfState.configs.get(a.body.tunnel_id).ingress[0].service, "http://localhost:50000");
});

test("malformed requests are rejected", async () => {
  const code = b64(32); addInvite(code);
  for (const bad of [{}, { code }, { code, ...machine(), port: 80 }, { code: "short", ...machine() }]) {
    assert.equal((await enroll(bad)).status, 400);
  }
});

test("brute force from one IP is rate limited", async () => {
  for (let i = 0; i < 20; i++) await enroll({ code: b64(32), ...machine() }, "198.51.100.9");
  const code = b64(32); addInvite(code);
  assert.equal((await enroll({ code, ...machine() }, "198.51.100.9")).status, 429);
  assert.equal((await enroll({ code, ...machine() }, "198.51.100.10")).status, 200);
});
