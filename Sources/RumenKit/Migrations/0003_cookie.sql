-- A raw Cookie header sent on every request to the server, as curl -b would (decision 17:
-- kept here rather than in the Keychain, which prompted on every rebuild for a low-value
-- session cookie). NULL means none.
ALTER TABLE server ADD COLUMN cookie TEXT;
