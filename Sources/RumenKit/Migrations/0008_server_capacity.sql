-- What a host turned out to be able to take, so a later run does not rediscover it.
--
-- Keyed on the host rather than on a registered server, deliberately: one box often fronts
-- several roots (an ArcGIS services directory and a WFS, or a handful of proxied MapServers),
-- and its capacity belongs to the box. A server registered twice, or a WFS beside the ArcGIS
-- service it shares a machine with, should inherit what the other already learned.
--
-- Both numbers are the values an AdaptiveLimit had settled on when a run ended. They are a
-- starting point for the next run, never a ceiling: the user's concurrency preference and the
-- layer's advertised page size still bound what is asked for.
CREATE TABLE server_capacity (
    host        TEXT PRIMARY KEY,           -- scheme://host[:port], as ArcGISURL.origin gives it
    concurrency INTEGER,                    -- requests in flight the host sustained
    page_size   INTEGER,                    -- features per request the host sustained
    updated_at  TEXT NOT NULL
);
