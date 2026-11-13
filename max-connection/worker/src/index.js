// Max Connection enrollment Worker.
//
// One job: turn a single-use activation code into exactly one Cloudflare Tunnel
// (and DNS name) for exactly one machine, then hand that machine its tunnel token.
//
// Bindings (wrangler.toml):
//   DB            D1 database (schema.sql)
//   CF_API_TOKEN  secret: restricted token, Account > Cloudflare Tunnel:Edit + Zone(akior.io) > DNS:Edit
//   CF_ACCOUNT_ID, CF_ZONE_ID, ZONE_NAME, RESERVED_NAMES  plain vars
//
// Activation codes are created only from a trusted computer that already has
// wrangler access to this D1 database (admin/new-activation.*). There is no
// admin HTTP endpoint and no master credential outside Cloudflare.

const CODE_RE = /^[A-Za-z0-9_-]{40,64}$/;
const SECRET_RE = /^[A-Za-z0-9_-]{40,128}$/;
const MACHINE_ID_RE = /^[A-Za-z0-9-]{8,64}$/;
const MAX_FAILS_PER_10_MIN = 20;
const CF_API = "https://api.cloudflare.com/client/v4";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });
      if (request.method === "GET" && (url.pathname === "/activate" || url.pathname === "/")) return activationPage(env);
      if (request.method === "POST" && url.pathname === "/v1/enroll") return await enroll(request, env);
      if (request.method === "POST" && url.pathname === "/v1/update-port") return await updatePort(request, env);
      return json({ ok: false, error: "not_found" }, 404);
    } catch (err) {
      // Never echo upstream bodies: they can contain identifiers we do not want to leak.
      console.log("unhandled", err && err.message);
      return json({ ok: false, error: "server_error" }, 500);
    }
  },
};

// ---------------------------------------------------------------- enroll

async function enroll(request, env) {
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  if (await tooManyFailures(env, ip)) return json({ ok: false, error: "rate_limited" }, 429);

  const body = await readJson(request);
  const code = str(body.code);
  const machineSecret = str(body.machine_secret);
  const machineId = str(body.machine_id);
  const port = Number(body.port);
  const os = str(body.os).slice(0, 16);
  const arch = str(body.arch).slice(0, 16);
  const name = slugify(str(body.name));

  if (!CODE_RE.test(code) || !SECRET_RE.test(machineSecret) || !MACHINE_ID_RE.test(machineId) ||
      !Number.isInteger(port) || port < 1024 || port > 65535 || !name) {
    await recordAttempt(env, ip, false);
    return json({ ok: false, error: "invalid_request" }, 400);
  }

  const now = nowSec();
  const codeHash = await sha256(code);
  const machineHash = await sha256(machineSecret);

  // Atomic claim: a fresh unexpired code, or a code this same machine already claimed (retry).
  const claimed = await env.DB.prepare(
    `UPDATE invites
        SET state = CASE WHEN state = 'new' THEN 'claimed' ELSE state END,
            machine_hash = ?1,
            claimed_at = COALESCE(claimed_at, ?2)
      WHERE code_hash = ?3
        AND state != 'revoked'
        AND ((state = 'new' AND expires_at > ?2) OR (state IN ('claimed', 'done') AND machine_hash = ?1))
      RETURNING state`
  ).bind(machineHash, now, codeHash).first();

  if (!claimed) {
    await recordAttempt(env, ip, false);
    return json({ ok: false, error: "activation_invalid_or_used" }, 403);
  }
  await recordAttempt(env, ip, true);

  let machine = await env.DB.prepare("SELECT * FROM machines WHERE machine_hash = ?1").bind(machineHash).first();

  if (!machine) {
    const hostname = await pickHostname(env, name);
    await env.DB.prepare(
      `INSERT INTO machines (machine_hash, machine_id, hostname, tunnel_id, os, arch, port, created_at, updated_at)
       VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?7)`
    ).bind(machineHash, machineId, hostname, os, arch, port, now).run();
    machine = { machine_hash: machineHash, machine_id: machineId, hostname, tunnel_id: null, port };
  }

  // Each step below is idempotent, so an interrupted install can simply retry.
  if (!machine.tunnel_id) {
    const tunnelId = await createTunnel(env, `max-${machine.hostname.split(".")[0]}`);
    await env.DB.prepare("UPDATE machines SET tunnel_id = ?1, updated_at = ?2 WHERE machine_hash = ?3")
      .bind(tunnelId, now, machineHash).run();
    machine.tunnel_id = tunnelId;
  }
  await putIngress(env, machine.tunnel_id, machine.hostname, port);
  await ensureDns(env, machine.hostname, machine.tunnel_id);
  await env.DB.prepare("UPDATE machines SET port = ?1, os = ?2, arch = ?3, updated_at = ?4 WHERE machine_hash = ?5")
    .bind(port, os, arch, now, machineHash).run();
  const token = await tunnelToken(env, machine.tunnel_id);

  await env.DB.prepare("UPDATE invites SET state = 'done', done_at = COALESCE(done_at, ?1) WHERE code_hash = ?2")
    .bind(now, codeHash).run();

  return json({
    ok: true,
    hostname: machine.hostname,
    machine_id: machine.machine_id,
    tunnel_id: machine.tunnel_id,
    tunnel_token: token,
    mcp_base: `https://${machine.hostname}/mcp/`,
  });
}

// Recovery: the local MCP port changed (e.g. app data reset). Authenticated by the machine secret.
async function updatePort(request, env) {
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  if (await tooManyFailures(env, ip)) return json({ ok: false, error: "rate_limited" }, 429);
  const body = await readJson(request);
  const machineSecret = str(body.machine_secret);
  const port = Number(body.port);
  if (!SECRET_RE.test(machineSecret) || !Number.isInteger(port) || port < 1024 || port > 65535) {
    await recordAttempt(env, ip, false);
    return json({ ok: false, error: "invalid_request" }, 400);
  }
  const machine = await env.DB.prepare("SELECT * FROM machines WHERE machine_hash = ?1")
    .bind(await sha256(machineSecret)).first();
  if (!machine || !machine.tunnel_id) {
    await recordAttempt(env, ip, false);
    return json({ ok: false, error: "unknown_machine" }, 403);
  }
  await putIngress(env, machine.tunnel_id, machine.hostname, port);
  await env.DB.prepare("UPDATE machines SET port = ?1, updated_at = ?2 WHERE machine_hash = ?3")
    .bind(port, nowSec(), machine.machine_hash).run();
  return json({ ok: true, hostname: machine.hostname });
}

// ---------------------------------------------------------------- naming

async function pickHostname(env, slug) {
  const reserved = new Set(str(env.RESERVED_NAMES).split(",").map((s) => s.trim()).filter(Boolean));
  for (let i = 0; i < 50; i++) {
    const label = `mc-${slug}${i === 0 ? "" : "-" + (i + 1)}`.slice(0, 63);
    const host = `${label}.${env.ZONE_NAME}`;
    if (reserved.has(label)) continue;
    const taken = await env.DB.prepare("SELECT 1 FROM machines WHERE hostname = ?1").bind(host).first();
    if (taken) continue;
    const dns = await cf(env, "GET", `/zones/${env.CF_ZONE_ID}/dns_records?name=${encodeURIComponent(host)}`);
    if (dns.length) continue; // never take over a name someone already uses
    return host;
  }
  throw new Error("no_hostname_available");
}

function slugify(s) {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
}

// ---------------------------------------------------------------- Cloudflare API

async function createTunnel(env, name) {
  const secret = new Uint8Array(32);
  crypto.getRandomValues(secret);
  const result = await cf(env, "POST", `/accounts/${env.CF_ACCOUNT_ID}/cfd_tunnel`, {
    name: `${name}-${Date.now().toString(36)}`,
    config_src: "cloudflare",
    tunnel_secret: btoa(String.fromCharCode(...secret)),
  });
  return result.id;
}

async function putIngress(env, tunnelId, hostname, port) {
  await cf(env, "PUT", `/accounts/${env.CF_ACCOUNT_ID}/cfd_tunnel/${tunnelId}/configurations`, {
    config: {
      ingress: [
        {
          hostname,
          path: "^/mcp/",
          service: `http://localhost:${port}`,
          // Chat On Steroids only accepts its loopback Host header.
          originRequest: { httpHostHeader: `127.0.0.1:${port}` },
        },
        { service: "http_status:404" },
      ],
    },
  });
}

async function ensureDns(env, hostname, tunnelId) {
  const target = `${tunnelId}.cfargotunnel.com`;
  const existing = await cf(env, "GET", `/zones/${env.CF_ZONE_ID}/dns_records?name=${encodeURIComponent(hostname)}`);
  if (existing.length) {
    if (existing[0].type === "CNAME" && existing[0].content === target) return;
    throw new Error("dns_conflict");
  }
  await cf(env, "POST", `/zones/${env.CF_ZONE_ID}/dns_records`, {
    type: "CNAME", name: hostname, content: target, proxied: true, comment: "Max Connection",
  });
}

async function tunnelToken(env, tunnelId) {
  return await cf(env, "GET", `/accounts/${env.CF_ACCOUNT_ID}/cfd_tunnel/${tunnelId}/token`);
}

async function cf(env, method, path, body) {
  const res = await fetch(CF_API + path, {
    method,
    headers: { authorization: `Bearer ${env.CF_API_TOKEN}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.success === false) {
    const codes = (data.errors || []).map((e) => e.code).join(",");
    throw new Error(`cloudflare_api ${method} ${path.split("?")[0].replace(/[0-9a-f-]{32,}/g, ":id")} ${res.status} ${codes}`);
  }
  return data.result;
}

// ---------------------------------------------------------------- helpers

async function tooManyFailures(env, ip) {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM attempts WHERE ip = ?1 AND ok = 0 AND ts > ?2")
    .bind(ip, nowSec() - 600).first();
  return (row && row.n) >= MAX_FAILS_PER_10_MIN;
}

async function recordAttempt(env, ip, ok) {
  await env.DB.prepare("INSERT INTO attempts (ts, ip, ok) VALUES (?1, ?2, ?3)").bind(nowSec(), ip, ok ? 1 : 0).run();
  await env.DB.prepare("DELETE FROM attempts WHERE ts < ?1").bind(nowSec() - 86400).run();
}

async function sha256(s) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function readJson(request) {
  try { return (await request.json()) || {}; } catch { return {}; }
}

function str(v) { return typeof v === "string" ? v.trim() : ""; }
function nowSec() { return Math.floor(Date.now() / 1000); }

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}

function activationPage(env) {
  const releases = str(env.RELEASES_URL) || "https://github.com/yosiwizman-reviewer/chatgpt-computer-mcp/releases";
  // The code lives in the URL fragment (#...), which browsers never send to the server.
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>Max Connection activation</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 16px;background:#fff;color:#111}
@media (prefers-color-scheme:dark){body{background:#151515;color:#eee}}
code{word-break:break-all;background:#8882;padding:2px 6px;border-radius:4px}button,a.b{font-size:18px;padding:10px 16px;margin:6px 6px 6px 0;display:inline-block}</style></head>
<body><h1>Max Connection</h1>
<p id="s">This page holds a private, single-use activation link.</p>
<ol><li>Download the installer: <a class="b" href="${releases}/latest">Max Connection installers</a></li>
<li><button id="c">Copy activation link</button> — the installer reads it from the clipboard.</li>
<li>Run the installer and approve the operating-system prompts.</li></ol>
<p>Do not share this link. It works once and expires.</p>
<script>const h=location.hash.slice(1);const s=document.getElementById('s');
if(!/^[A-Za-z0-9_-]{40,64}$/.test(h)){s.textContent='This link is incomplete. Ask for a new activation link.';document.getElementById('c').disabled=true}
document.getElementById('c').onclick=()=>navigator.clipboard.writeText(location.href).then(()=>{s.textContent='Activation link copied.'});</script>
</body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" } });
}

export const _test = { slugify, sha256 };
