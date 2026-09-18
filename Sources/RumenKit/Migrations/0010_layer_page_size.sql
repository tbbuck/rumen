-- A page size belongs to the layer, a width to the server.
--
-- How many features come back in one request is decided by the layer: its advertised
-- maxRecordCount or CountDefault, how many fields it has, and how heavy its geometry is. A
-- points layer and a polygon layer on one machine are not alike, and remembering one number for
-- both meant every download started from a size learned somewhere it did not apply.
--
-- How many requests the machine will take at once is the opposite: that is the machine's, and
-- every layer on it shares the answer. So the two numbers part company here.
--
-- The column survives a re-crawl the way `transport` does: the layer upsert names the columns
-- it overwrites, and this is not one of them.
ALTER TABLE layer ADD COLUMN page_size INTEGER;

DROP TABLE IF EXISTS server_capacity;

CREATE TABLE server_capacity (
    server_id   INTEGER PRIMARY KEY,        -- server.id; removed with the server it belongs to
    concurrency INTEGER NOT NULL,           -- requests in flight the server sustained
    updated_at  TEXT NOT NULL
);
