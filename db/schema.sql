-- Gatekeeper SQLite schema
-- Default database file: /var/lib/goto/gatekeeper.db
-- GoTo opens it read-only; writes happen through the root-only helper
-- scripts (add-zone.sh, add-host.sh) on the Gatekeeper itself.

-- Zones are fully dynamic: GoTo reads this table at session time.
--   name      zone / principal name (e.g. "marketing", "eng", "lab-a")
--   inherits  comma-separated zone names whose hosts this zone also sees
--             (resolved transitively, cycles are tolerated)
--   superuser 1 = sees every host in every zone and gets the "Shell>" option
CREATE TABLE IF NOT EXISTS zone (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  name      TEXT    NOT NULL UNIQUE,
  inherits  TEXT    DEFAULT NULL,
  superuser INTEGER NOT NULL DEFAULT 0
);

-- Destination hosts.
--   zone           comma-separated zone names this host belongs to
--   enabled        0 = registered but not offered in the menu (opt-in gate:
--                  going live requires an explicit add-host.sh --enable)
--   authorization  1 = self-managed authorization: GoTo connects with the
--                  caller's real login instead of the role-derived user,
--                  because the host's AuthorizedPrincipalsFile does its own
--                  per-user check
CREATE TABLE IF NOT EXISTS VM (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  nameID          TEXT    NOT NULL UNIQUE,
  ipv4            TEXT    NOT NULL,
  zone            TEXT    NOT NULL,
  enabled         INTEGER NOT NULL DEFAULT 0,
  "authorization" INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_vm_zone ON VM(zone);

-- Example zone rows (replace with your own):
-- INSERT INTO zone (name) VALUES ('marketing'), ('sales');
-- INSERT INTO zone (name, superuser) VALUES ('admin', 1);
-- A zone that also sees other zones' hosts:
-- INSERT INTO zone (name, inherits) VALUES ('analyst', 'marketing,sales');

-- Example host rows:
-- INSERT INTO VM (nameID, ipv4, zone, enabled) VALUES
--   ('crm-prod',     '192.168.10.11', 'marketing',       1),
--   ('analytics-01', '192.168.10.12', 'marketing,sales', 1);
