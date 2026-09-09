# 🗝 Gatekeeper: GoTo

<p align="center">
  <img
    src="./images/icon.jpg"
    alt="The Doors of Durin — Speak, friend, and enter"
    width="300"
  />
</p>

> Born at the [Pierre Auger Observatory](https://www.auger.org.ar/) — the
> world's largest cosmic-ray observatory — where it replaced a sprawling
> port-forwarding perimeter spanning remote detector stations in the
> Argentinian Pampa. As seen on
> [Medium](https://medium.com/@juampi.gnr/rbac-over-ssh-yes-you-read-it-right-f71ecf688c22), where the
> full architecture walkthrough is published.

## What is GoTo?

**GoTo** is the **single, authoritative entry point** to your infrastructure.

It is not a convenience jump host.
It is a **policy-enforcing bastion** designed to ensure that every access is:
- intentional
- authenticated
- role-aware
- auditable

You don't "log in and explore".
You **arrive with an identity**, and Gatekeeper decides what doors exist for you.

## Why GoTo Exists

Traditional SSH access assumes trust *after* login.
Gatekeeper enforces trust **before** entry.

It ensures that:
- 🔐 **Identity is cryptographically proven** (SSH CA, certificates, principals, technical users)
- 🧭 **Routing is role-based**, not user-chosen
- 👤 **Operations inside endpoints** are governed by each technical user's permissions
- 🏠 **Connecting feels like being local** through traffic redirection & near-local DNS resolution — no port-forwarding, just real routing (a pseudo-VPN over plain SSH)
- 🧱 **Shell access to the bastion is contained**, avoiding exposure by adding yet another attack vector
- 📜 **Access is governed** by principals and **operations are governed** by technical users

And it does all of that with **pure SSH**. No directory server, no VPN
concentrator, no agent daemons, no online authority that must be up for
authentication to work. Endpoints verify a signature against one public key —
offline, with stock OpenSSH. One system gives you **authentication,
authorization, and remote-work networking**, with fewer moving parts than any
of the alternatives it replaces — and each part it *doesn't* have is one less
point of failure and one less thing to attack.

## Architecture

```
USER LAPTOP
┌───────────────────────────────────┐
│ ssh alice@gate.example.com        │
│ cert principals:                  │
│   [ marketing, operator ]         │
└─────────────────┬─────────────────┘
                  │ SSH
GATEKEEPER VM
┌───────────────────────────────────┐
│ sshd verifies cert against CA     │
│   └─ ForceCommand ──> GoTo        │
│        · zone + tech user         │
│          read from principals     │
│        · destination menu         │
│          from SQLite              │
│                                   │
│ ssh marketing-operator@endpoint   │
│   (role cert, source-locked       │
│    to the Gatekeeper IP)          │
└─────────────────┬─────────────────┘
                  │ SSH
ENDPOINT VM
┌───────────────────────────────────┐
│ sshd: CA-signed certs only        │
│   AuthorizedKeysFile none         │
│   principals file gates login     │
│                                   │
│ session runs as unix user         │
│   marketing-operator              │
└───────────────────────────────────┘
```

The user never picks a login on the endpoint and never holds a credential
that works there directly — GoTo maps their certificate to a **technical
user** and connects with a role credential that is cryptographically useless
from anywhere but the Gatekeeper.

## How it works

**Users hold certificates. Certificates hold principals. Principals map to
zones and technical users.**

1. **A zone is an access domain** — `marketing`, `lab-a`, `eng`, anything.
   Zones live in a small SQLite table on the Gatekeeper; nothing is
   hardcoded. Each destination host is registered in one or more zones.

2. **A user's certificate carries one or two principals**: the zone, and
   optionally a technical-user name. The CA signs it once; from then on the
   cert *is* the user's identity and authorization, verifiable offline by
   any endpoint.

3. **Each principal combination maps to a technical user** on the endpoint —
   the zone name, optionally suffixed:

   | Cert principals            | Technical user on the endpoint |
   |----------------------------|--------------------------------|
   | `marketing`                | `marketing`                    |
   | `marketing`, `operator`    | `marketing-operator`           |
   | `marketing`, `observer`    | `marketing-observer`           |

   `observer` / `operator` is the read-only vs read-write split — or more
   generally, low vs high permissions. The suffixes are configurable; define
   the levels your organization needs.

   **Technical users are how teams define their own authorization.** They
   are ordinary unix accounts, so whoever owns an endpoint decides what each
   one may do with the tools they already know — no CA or Gatekeeper change
   involved. Grant a Samba share to a zone (`valid users = @marketing`, with
   the observer variant read-only via `read list`); serve an internal web
   page only to a technical user (file permissions on the docroot, or HTTP
   auth backed by PAM/system users); scope sudo rules, group memberships,
   database socket access — anything unix permissions can express.

4. **GoTo does the mapping at session time.** When a user connects, sshd
   verifies their cert against the CA, the ForceCommand extracts the
   principals, and GoTo shows only the destinations their zone allows. Pick
   one, and GoTo opens the onward SSH as the technical user, using a
   per-role credential (also CA-signed, locked to the Gatekeeper's source
   IP). Users cannot choose their route or their endpoint identity — the
   certificate chooses for them.

5. **Zone inheritance builds hierarchies without duplication.** A zone can
   list other zones it inherits: its members then see those zones' hosts
   too, transitively. Say `marketing` and `sales` each have their own
   hosts; an `analyst` zone that inherits `marketing,sales` sees both sets,
   and a zone flagged **superuser** sees every host in every zone and gets
   a shell on the Gatekeeper itself. Register a host in `sales` once and
   every inheriting zone sees it immediately — no per-zone duplication, no
   drift.

6. **The pseudo-VPN.** GoTo's "work remotely" option hands the user a
   ready-made [sshuttle](https://github.com/sshuttle/sshuttle) command using
   `-Nr`, which auto-routes every network the Gatekeeper itself can reach —
   with DNS — through the user's existing SSH session. The ergonomics of a
   VPN with no VPN server, no shared VPN credentials, nothing new
   listening, and no hardcoded subnet lists to maintain or leak.

7. **Hosts join explicitly.** New hosts register with `enabled=0` and only
   appear in menus after an explicit enable — an intentional provisioning
   gate. Hosts flagged `authorization=1` are *self-managed*: GoTo connects
   with the caller's own login and the host's `AuthorizedPrincipalsFile`
   makes its own per-user decision.

The result is RBAC that is **simpler to reason about, easier to set up, and
safer to operate** than gluing together an identity provider, a VPN, and
per-host key management — because it's one mechanism (SSH certificates)
doing authentication and authorization in one place, enforced by software
(OpenSSH) that your hosts already run.

## Repository layout

```
ca/         setup-ca.sh, mintcert.sh, create-role-certs.sh
gatekeeper/ setup-gatekeeper.sh, add-zone.sh, add-host.sh,
            sshd_config.gatekeeper, goto/
endpoint/   setup-endpoint.sh, sshd_config.endpoint
db/         schema.sql
systemd/    goto-agent@.service, goto-agent-load
images/     icon.jpg
```

One `setup-*.sh` per machine role: `setup-ca.sh` runs on the CA VM,
`setup-gatekeeper.sh` on the Gatekeeper, and `setup-endpoint.sh` runs *from*
the Gatekeeper against each endpoint.

## Quick start

Three machines, visited **in order, once each for setup**: the **CA VM**
(minimal, ideally kept offline-ish — it's also your permanent signing seat),
the **Gatekeeper**, and your **endpoints** (which you never log into at all —
they're deployed remotely). Debian/Ubuntu and openSUSE/SLES are supported.
OpenSSH ≥ 8.2 everywhere; Node.js ≥ 20 LTS on the Gatekeeper.

### 1. CA VM — once

```bash
cd ca && ./setup-ca.sh            # FIDO2/YubiKey CA (PIN + touch per signature)
# or, without a hardware token:
./setup-ca.sh --plain
```

### 2. Gatekeeper — once

```bash
cd gatekeeper
./setup-gatekeeper.sh \
  -z marketing,sales,finance \
  -a gate.example.com \
  -c root@ca-vm:/etc/ssh/ca/user_ca_key.pub
```

`-c` pulls the CA public key straight from the CA VM — no manual copying.
This initializes the SQLite database, installs GoTo, the hardened
`sshd_config`, per-zone role keypairs, per-role ssh-agents, and the
endpoint deployment tooling.

### 3. CA VM — sign roles, mint users

The CA is where all signing lives permanently, so this is its normal job,
not a setup detour:

```bash
create-role-certs.sh -g gate.example.com -i 203.0.113.10
```

What this does: it connects to the Gatekeeper (`-g`) over SSH, pulls down
every role public key from `/etc/goto/keys/`, signs each one with its
role name as the certificate principal (`marketing`, `marketing-operator`,
...) and with the critical option `source-address=203.0.113.10` (`-i` — the
Gatekeeper's public IP, so endpoints reject these certs coming from any
other address), assigns incrementing audit serials from the CA's counter,
pushes the certificates back to `/etc/goto/keys/`, and restarts the
per-role agents so they load key + fresh cert. `-g` and `-i` are separate
because `-g` is just the SSH target (may be a hostname or jump alias) while
`-i` must be the literal source IP the endpoints will see.

Then mint your users:

```bash
mintcert.sh -u alice -p marketing -t operator -e +180d \
  -k ./alice_ed25519.pub -g gate.example.com
```

`mintcert.sh` signs Alice's key with the `marketing,operator` principals
and provisions her login on the Gatekeeper over SSH — nothing to do there
manually. All validities are expressed in days (`+180d`, `+30d`, ...).

### 4. Endpoints — one command each, from the Gatekeeper

```bash
setup-endpoint.sh -n crm-prod -i 192.168.10.11 -z marketing --enable
```

This pushes the CA key, the hardened `sshd_config`, and itself to the host
over your existing (pre-Gatekeeper) root SSH access, runs the provisioning
remotely, registers the host, and — with `--enable` — flips it live. Drop
`--enable` to review first and go live later with
`add-host.sh --enable crm-prod`.

### Done — connect

The user drops the signed cert into `~/.ssh` **next to their private key,
keeping the `<keyname>-cert.pub` naming** (e.g. `id_ed25519` and
`id_ed25519-cert.pub`). OpenSSH picks the certificate up automatically —
no `-i`, no `-o CertificateFile`:

```bash
ssh alice@gate.example.com
```

GoTo greets Alice with the destinations her zone allows, the sshuttle
pseudo-VPN command, and — for superuser zones — a shell.

### Adding a zone later

```bash
add-zone.sh -z lab-a                                       # Gatekeeper
create-role-certs.sh -g gate.example.com -i 203.0.113.10   # CA VM
setup-endpoint.sh -n lab-a-daq -i 10.20.0.5 -z lab-a --enable
```

## Operations

- **List hosts**: `add-host.sh --list`
- **Inspect any cert**: `ssh-keygen -Lf <cert>.pub`
- **Trace a failing auth**: run `sshd -ddd -e` on the target for a
  single-connection trace
- **Revoke a cert**: append `serial: <n>` to a `RevokedKeys` file on the
  endpoints (add `RevokedKeys /etc/ssh/revoked_keys` to sshd_config)
- **Decommission a host**: `setup-endpoint.sh -r -n <name> -i <ip> -z <zones>`
  (reverts the host and removes its database row)
- **Delete a user**: `mintcert.sh -d alice -g gate.example.com` (then revoke
  their serial if the cert hasn't expired)

## How secure is this, compared to the alternatives?

Every access-control system reduces to three questions: **what must be
online for authentication to work, what must be protected for the system to
stay trustworthy, and what does a compromise of each part cost you.**
Gatekeeper's answers are unusually short.

**What must be online**: nothing but the destination's own `sshd`.
Certificate verification is an offline signature check against one public
key already on the host's disk. If the database, the Gatekeeper, or the CA
VM are all down, an existing cert still authenticates anywhere the network
reaches. There is no login-path dependency on any central service.

**What must be protected**: one CA private key — which, in the default
setup, is not a file at all but a FIDO2 credential inside a hardware token
that requires PIN and physical touch per signature. Stealing the CA VM's
disk yields a useless handle stub. The secondary secrets (role keys) are
individually locked to the Gatekeeper's source IP, so exfiltrating them is
also useless.

Compared to mainstream RBAC systems:

- **Passwords / authorized_keys sprawl.** Keys never expire, carry no
  identity, and accumulate silently in home directories; offboarding means
  hunting them across every host. Certificates expire on their own, carry a
  Key ID and an audit serial, and removing trust is a per-host **one-file**
  concern (the CA key) rather than a per-user-per-host hunt.

- **VPN + firewall rules.** A VPN authenticates you to *a network*, then
  hopes firewall rules approximate authorization — lateral movement comes
  free with the tunnel. It's also an online authority: the concentrator
  must be up, holds its own credential store, and is a high-value target
  listening on the internet. Gatekeeper authorizes **per host, per role,
  per session**, and its pseudo-VPN (sshuttle) rides the same audited SSH
  session — no second credential system, no second listener.

- **Kerberos / FreeIPA / LDAP.** The gold standard for instant revocation —
  and that is a real advantage over certificates (see the trade-off below).
  The price is a KDC/directory that must be **reachable and healthy for
  every single authentication**, clock synchronization as a hard
  dependency, a substantial setup and maintenance burden, and a central
  service whose compromise is instantly total. Gatekeeper trades instant
  revocation for having **no online authority at all** — a trade that
  favors exactly the environment this was born in at the Pierre Auger
  Observatory: remote stations, intermittent links, small teams.

- **Commercial/OSS access platforms (Teleport-style).** Feature-rich —
  session recording, SSO, web UIs — but they put a proprietary agent on
  every node, run large privileged daemons, and move your trust root into a
  much bigger codebase with its own CVE cadence. Gatekeeper's endpoints run
  **stock OpenSSH and nothing else**: no agent to install, no new port to
  open, no vendor in the trust chain. The entire policy engine is a few
  hundred lines you can read in one sitting.

- **DNAT / port-forwarding perimeters** (what this replaced). Every rule is
  an implicit, identity-free trust grant tied to a source IP, and the rule
  set only ever grows. Gatekeeper collapses hundreds of such rules into one
  audited choke point where every access names a person, a role, a serial,
  and an expiry.

**The honest trade-offs**, so you deploy with eyes open:

1. **Revocation is eventual, not instant.** A signed cert is valid until it
   expires unless a `RevokedKeys` entry reaches every endpoint. Mitigate
   with short validities in days — minting is cheap — and treat KRL
   distribution as part of your incident playbook.
2. **The Gatekeeper is a choke point by design.** For availability, that
   only affects *new* routed sessions (auth itself has no dependency on
   it). For security, a shell escape on the Gatekeeper is a full-perimeter
   event — which is precisely why GoTo is a ForceCommand, shells are
   restricted to superuser zones, and the bastion runs nothing else.
3. **`ssh -N` leaves no ForceCommand trace.** Forwarding is disabled in the
   shipped configs, which closes the practical exposure; if you ever enable
   cert-scoped `permitopen`, correlate `-N` connections from sshd's
   VERBOSE logs.

## Operational security notes

- **Role credential exposure model**: role keys are `root:goto 0640` and the
  per-role agent sockets are `root:goto 0660`, so any `goto`-group member
  could technically reach any role credential *if they had arbitrary code
  execution on the Gatekeeper*. They don't: the ForceCommand is the
  enforcement boundary, and only superuser-zone users get a shell.
- **Per-role agents exist for a reason**: OpenSSH refuses (fatally, for
  non-root) to read a private key owned by another UID, so GoTo cannot simply
  `-i` root-owned keys. Testing as root masks this — the check downgrades to
  a warning. Always test as a real minted user.
- **SQLite access model**: the database file is `root:goto 0640` and GoTo
  opens it strictly read-only. Keep it that way — group-writable would let
  any zone user grant themselves destinations. All mutations belong in the
  root-only helper scripts (`add-zone.sh`, `add-host.sh`).

## License

MIT — see [LICENSE](LICENSE).
