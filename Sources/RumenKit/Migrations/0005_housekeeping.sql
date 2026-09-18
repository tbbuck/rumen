-- The one-off Keychain → app-database cookie move (decision 17) is gone from the app; its
-- marker setting goes with it.
DELETE FROM setting WHERE key = 'cookies_moved_from_keychain';
