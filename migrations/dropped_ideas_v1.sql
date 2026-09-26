-- EFFECTIVE-1291 (EFFECTIVE-392 slice): persisted model for dropped ideas.
--
-- An agent drops an idea with ONE sentence plus a citation — no domain,
-- priority, effort, outcome, or acceptance criteria required at drop time
-- (that shaping happens later, in the digester described by EFFECTIVE-392).
--
-- status lifecycle: 'pending' (default, awaiting digest) -> 'digested'
-- (shaped into a gap or attached as a receipt) -> 'discarded' (surfaced to
-- a human but not shapeable, per EFFECTIVE-392 AC5) or 'unshapeable'.
CREATE TABLE IF NOT EXISTS dropped_ideas (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    sentence   TEXT    NOT NULL,
    citation   TEXT    NOT NULL,
    status     TEXT    NOT NULL DEFAULT 'pending',
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX IF NOT EXISTS dropped_ideas_citation_idx
    ON dropped_ideas (citation);

CREATE INDEX IF NOT EXISTS dropped_ideas_status_idx
    ON dropped_ideas (status);
