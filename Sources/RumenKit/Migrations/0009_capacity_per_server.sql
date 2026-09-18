-- Capacity belongs to a registered server, not to a host name.
--
-- It used to be keyed on the host, on the reasoning that one box often fronts several roots and
-- its capacity belongs to the box. That holds for a council's own machine. It is wrong for a
-- shared one: services-eu1.arcgis.com and utility.arcgis.com are Esri's, fronting thousands of
-- unrelated organisations, and what one tenant's layer coped with says nothing about another's.
-- One slow layer taught every other customer's download to start small.
--
-- Politeness to the box is unaffected. The in-session limiter still counts requests in flight
-- per origin, so two registered servers on one machine still share one budget while they run;
-- only what is carried between runs is narrowed.
--
-- The existing rows are dropped rather than carried across. They were learned by the throughput
-- comparison that this release fixes, and a starting point that is wrong is worse than none.
DROP TABLE IF EXISTS server_capacity;

CREATE TABLE server_capacity (
    server_id   INTEGER PRIMARY KEY,        -- server.id; removed with the server it belongs to
    concurrency INTEGER,                    -- requests in flight the server sustained
    page_size   INTEGER,                    -- features per request the server sustained
    updated_at  TEXT NOT NULL
);
