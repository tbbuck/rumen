-- An HTTP proxy for every request to this server, as curl --proxy would: "http://host:port".
-- Per server rather than global, because the servers that need one (a council behind a
-- corporate egress, an endpoint reachable only through a tunnel) sit alongside ones that must
-- not be proxied. NULL means a direct connection.
ALTER TABLE server ADD COLUMN proxy_url TEXT;
