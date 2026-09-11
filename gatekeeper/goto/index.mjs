#!/usr/bin/env node
// GoTo — Gatekeeper ForceCommand
// Runs for every inbound SSH session on the Gatekeeper. Extracts the
// principals from the caller's CA-signed certificate, resolves allowed
// destinations from the SQLite database (fully dynamic zones), and proxies
// the connection with the matching role credential.

import { spawn } from "child_process";
import Database from "better-sqlite3";
import chalk from "chalk";
import inquirer from "inquirer";
import process from "process";
import { mkdtemp, rm, writeFile, readFile, chmod, mkdir } from "fs/promises";
import { tmpdir } from "os";
import { basename } from "path";

// ── Graceful exit ─────────────────────────────────────────────────────────────

function gracefulExit(code = 0, reason = "normal exit", trace = "") {
  try {
    if (code !== 0 && !String(trace).includes("SIGINT"))
      console.error(`\nExit (${code}) ${reason}:\n  ${trace}`);
  } catch (_) {}
  process.exit(code);
}

["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"].forEach((sig) => {
  process.on(sig, () =>
    gracefulExit(128 + process.binding("constants").os.signals[sig], sig, sig),
  );
});

process.on("uncaughtException", (err) => gracefulExit(2, "UncaughtException", err));
process.on("unhandledRejection", (r) => gracefulExit(2, "UnhandledRejection", r));

// ── Configuration ─────────────────────────────────────────────────────────────

const CONFIG_PATH = process.env.GOTO_CONFIG ?? "/etc/goto/config.json";

let config;
try {
  config = JSON.parse(await readFile(CONFIG_PATH, "utf-8"));
} catch (error) {
  gracefulExit(2, `Cannot read config at ${CONFIG_PATH}`, error);
}

const DB_PATH       = config.db?.path      ?? "/var/lib/goto/gatekeeper.db";
const KEYS_DIR      = config.keysDir       ?? "/etc/goto/keys";
const ENDPOINT_PORT = String(config.endpointPort ?? 22);
const GATE_ADDRESS  = config.gatekeeper?.address ?? "gatekeeper";
const GATE_EXCLUDE  = config.gatekeeper?.sshuttleExclude ?? GATE_ADDRESS;

const originalCommand = process.env.SSH_ORIGINAL_COMMAND ?? "";
const userExposedAuth = process.env.SSH_USER_AUTH;

// ── sshuttle pass-through ─────────────────────────────────────────────────────

const isSshuttle =
  /python/.test(originalCommand) && /assembler\.py/.test(originalCommand);

if (isSshuttle) {
  const proc = spawn("/bin/sh", ["-c", originalCommand], { stdio: "inherit" });
  proc.on("close", () => gracefulExit());
  proc.on("error", (err) => gracefulExit(1, "sshuttle error", err));
} else {
  // ── Database (SQLite, read-only) ────────────────────────────────────────────

  let db;
  try {
    db = new Database(DB_PATH, { readonly: true, fileMustExist: true });
  } catch (error) {
    gracefulExit(2, `Cannot open database at ${DB_PATH}`, error);
  }

  // ── Load dynamic zones ──────────────────────────────────────────────────────

  const zoneRows = db.prepare("SELECT name, inherits, superuser FROM zone").all();

  const zones = {};
  for (const row of zoneRows) {
    zones[row.name] = {
      inherits:  row.inherits ? row.inherits.split(",").map((z) => z.trim()) : [],
      // "!!" normalizes SQLite's numeric 0/1 into strict booleans at the boundary
      superuser: !!row.superuser,
    };
  }

  // ── Load enabled hosts ──────────────────────────────────────────────────────

  const rows = db
    .prepare('SELECT nameID, ipv4, zone, "authorization" FROM VM WHERE enabled = 1')
    .all();

  db.close();

  const hostdb = {};        // zone -> { nameID: ipv4 }
  const hostAuthByIp = {};  // ipv4 -> self-managed-authorization flag

  for (const row of rows) {
    if (row.ipv4) hostAuthByIp[row.ipv4] = !!row.authorization;

    for (const zone of row.zone.split(",").map((z) => z.trim())) {
      if (!zones[zone]) continue; // unknown zones are not routable
      (hostdb[zone] ??= {})[row.nameID] = row.ipv4;
    }
  }

  // ── Parse the connecting user's certificate ─────────────────────────────────

  let principals = [];

  try {
    // Scoped per-caller UID: a shared /tmp/goto/ would end up owned by
    // whichever user connects first, permanently locking out every other
    // user (EACCES on mkdtemp) until an admin manually fixes its permissions.
    const sessionRoot = `${tmpdir()}/goto-${process.getuid()}`;
    await mkdir(sessionRoot, { recursive: true, mode: 0o700 });
    const sessionTmp = await mkdtemp(`${sessionRoot}/`);
    const pubKeyPath = `${sessionTmp}/${basename(userExposedAuth)}.pub`;

    await chmod(sessionTmp, 0o700);

    // SSH_USER_AUTH holds "publickey <type> <blob>"; keep type + blob
    const raw = (await readFile(userExposedAuth, "utf-8")).trim().split(" ");
    await writeFile(pubKeyPath, `${raw[1]} ${raw[2]}`);

    const sshKeygen = spawn("ssh-keygen", ["-Lf", pubKeyPath]);
    const certInfo = await new Promise((resolve, reject) => {
      sshKeygen.stdout.on("data", (d) => resolve(d.toString()));
      sshKeygen.on("error", (e) => reject(e));
    });

    // Robust principal extraction: capture every indented, colon-free line
    // under "Principals:" (the next field header contains a colon, which ends
    // the block). Handles hyphenated principals and any principal count
    // without assuming fixed line positions.
    const match = /Principals:\s*\n(?<block>(?:[ \t]+[^:\n]+(?:\n|$))+)/.exec(certInfo);
    principals = match
      ? match.groups.block.split("\n").map((l) => l.trim()).filter(Boolean)
      : [];

    await rm(sessionTmp, { recursive: true, force: true });
  } catch (error) {
    gracefulExit(2, "SSH-01 certificate parsing error", error);
  }

  const [principal, techUser] = [principals[0] ?? "", principals[1] ?? ""];

  // Principals come from a CA-signed cert, but they end up in an ssh argv —
  // enforce a conservative charset anyway.
  const SAFE = /^[a-z0-9][a-z0-9-]*$/;
  if (!principal || !SAFE.test(principal) || (techUser && !SAFE.test(techUser))) {
    console.error(chalk.bgRed("Access denied: invalid or missing certificate principal"));
    gracefulExit(1);
  }

  const zoneDef = zones[principal];
  if (!zoneDef) {
    console.error(chalk.bgRed(`Access denied: unknown zone "${principal}"`));
    gracefulExit(1);
  }

  // Effective unix user on the endpoint:
  //   ["marketing"]             -> marketing
  //   ["marketing","operator"]  -> marketing-operator
  //   ["marketing","observer"]  -> marketing-observer
  const effectiveUser =
    techUser && techUser !== principal ? `${principal}-${techUser}` : principal;

  // ── Resolve destination scope (dynamic inheritance) ─────────────────────────

  function resolveZone(name, seen = new Set()) {
    if (seen.has(name)) return {}; // cycle guard
    seen.add(name);
    const out = { ...(hostdb[name] ?? {}) };
    for (const parent of zones[name]?.inherits ?? [])
      Object.assign(out, resolveZone(parent, seen));
    return out;
  }

  const destinations = zoneDef.superuser
    ? Object.assign({}, ...Object.keys(zones).map((z) => hostdb[z] ?? {}))
    : resolveZone(principal);

  if (Object.keys(destinations).length === 0) {
    console.error(chalk.bgRed(`Access denied: no destinations for zone "${principal}"`));
    gracefulExit(1);
  }

  // ── Interactive destination menu ────────────────────────────────────────────

  const choices = [
    { name: "Work remotely (sshuttle)", value: "sshuttle" },
    ...Object.entries(destinations).map(([name, host]) => ({
      name: `${name} (${host ?? "?"})`,
      value: host,
    })),
  ];

  if (zoneDef.superuser) choices.push({ name: "Shell>", value: "shell" });

  const { destination } = await inquirer.prompt([
    { type: "list", name: "destination", message: "Select a destination:", choices },
  ]);

  // ── Dispatch ────────────────────────────────────────────────────────────────

  if (destination === "shell") {
    if (zoneDef.superuser) {
      console.log(chalk.bgGreen("Opening shell"));
      spawn("/bin/bash", { stdio: "inherit" });
    }
  } else if (destination === "sshuttle") {
    // -N auto-detects routable networks from the Gatekeeper's own routing
    // table — no hardcoded subnet lists to maintain or leak.
    const sshuttleCmd =
      `sshuttle -Nr ${process.env.USER}@${GATE_ADDRESS} ` +
      `--latency-buffer-size 65536 --exclude ${GATE_EXCLUDE} --dns`;

    console.log(chalk.bgBlue("\nRun this on your local machine:"));
    console.log(chalk.bold(sshuttleCmd));
  } else {
    // Self-managed-authorization hosts get the caller's real SSH login
    // instead of the role-derived user.
    const selfManaged = hostAuthByIp[destination] === true;
    const sshUser = selfManaged && process.env.USER ? process.env.USER : effectiveUser;

    // Role keys are root:goto 0640. OpenSSH's private-key permission check
    // ("Permissions ... too open") is self-protective — it only fires when
    // the file's *owner* loads it with loose permissions — so any minted
    // user (never the owner; role keys are always owned by root) can read
    // and use their mapped role key directly. No agent/broker needed.
    const sshArgs = [
      "-p", ENDPOINT_PORT,
      "-i", `${KEYS_DIR}/${effectiveUser}`,
      `${sshUser}@${destination}`,
    ];

    console.log(chalk.bgGreen(`Connecting to ${sshUser}@${destination}`));
    spawn("/usr/bin/ssh", sshArgs, { stdio: "inherit", env: process.env });
  }
}
