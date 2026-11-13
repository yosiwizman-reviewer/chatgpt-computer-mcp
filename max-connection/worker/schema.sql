-- Max Connection enrollment database (Cloudflare D1).
-- Only hashes of activation codes and machine secrets are stored.

CREATE TABLE IF NOT EXISTS invites (
  code_hash     TEXT PRIMARY KEY,          -- sha256(code), hex
  created_at    INTEGER NOT NULL,          -- unix seconds
  expires_at    INTEGER NOT NULL,          -- unix seconds
  note          TEXT,
  state         TEXT NOT NULL DEFAULT 'new' CHECK (state IN ('new', 'claimed', 'done', 'revoked')),
  machine_hash  TEXT,                      -- sha256(machine_secret) of the machine that claimed it
  claimed_at    INTEGER,
  done_at       INTEGER
);

CREATE TABLE IF NOT EXISTS machines (
  machine_hash  TEXT PRIMARY KEY,          -- sha256(machine_secret), hex
  machine_id    TEXT NOT NULL,
  hostname      TEXT NOT NULL UNIQUE,      -- e.g. mc-office-mac.akior.io
  tunnel_id     TEXT,
  os            TEXT,
  arch          TEXT,
  port          INTEGER,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS attempts (
  ts  INTEGER NOT NULL,
  ip  TEXT NOT NULL,
  ok  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS attempts_ip_ts ON attempts (ip, ts);
