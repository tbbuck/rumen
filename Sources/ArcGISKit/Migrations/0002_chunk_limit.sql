-- Per-chunk page size, so a chunk the server cannot serve in one go can be split into
-- smaller ones (adaptive splitting). NULL means the run's page size.
ALTER TABLE download_chunk ADD COLUMN "limit" INTEGER;
