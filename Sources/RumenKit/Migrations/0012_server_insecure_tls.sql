-- Accept whatever certificate this server presents, as curl --insecure would: self-signed,
-- expired, issued for another name, or chained to a root the system does not trust. Council
-- and utility endpoints serve all of these. Per server, like the proxy, so switching it on for
-- one box never weakens the check anywhere else. 0 verifies as normal.
ALTER TABLE server ADD COLUMN insecure_tls INTEGER NOT NULL DEFAULT 0;
