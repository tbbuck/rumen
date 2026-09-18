-- Folder listings as rows (M8): a folder the shallow crawl could not read (a 500, a timeout, a
-- permission wall) used to have no row at all, because folders were derived from the paths of
-- the services under them. Now every folder a directory lists is recorded, with the outcome of
-- listing it, so the tree can show a failed folder with its error and offer Retry, and the
-- deep crawl and column search know what they could not see.
CREATE TABLE folder (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id    INTEGER NOT NULL,
    path         TEXT NOT NULL,                 -- 'A' at the root, 'A/B' nested
    parent_path  TEXT NOT NULL DEFAULT '',      -- '' = the root
    name         TEXT NOT NULL,                 -- the last path component
    last_error   TEXT,                          -- NULL when the last listing succeeded
    fetched_at   INTEGER,                       -- NULL until listed successfully
    UNIQUE (server_id, path)
);
