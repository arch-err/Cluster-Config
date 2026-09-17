SET LOCAL timezone = 'UTC';

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE ctfd_cockpit TO ctfd_cockpit_ingest, ctfd_cockpit_grafana;
GRANT USAGE ON SCHEMA cockpit TO ctfd_cockpit_ingest, ctfd_cockpit_grafana;

CREATE OR REPLACE FUNCTION cockpit.utc_timestamptz(value text)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$ SELECT value::timestamptz $$;

CREATE TABLE cockpit.ingest_batches (
    source              text NOT NULL,
    batch_id            uuid NOT NULL,
    endpoint            text NOT NULL CHECK (endpoint IN ('events', 'snapshot')),
    entity              text NOT NULL,
    schema_version      text NOT NULL,
    sent_at             timestamptz NOT NULL,
    checkpoint          bigint,
    snapshot_id         uuid,
    snapshot_chunk      integer,
    snapshot_complete   boolean,
    record_count        integer NOT NULL CHECK (record_count >= 0 AND record_count <= 1000),
    request_sha256      bytea NOT NULL CHECK (octet_length(request_sha256) = 32),
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (source, batch_id)
);

CREATE INDEX ingest_batches_time_idx
    ON cockpit.ingest_batches (source, ingested_at DESC);

CREATE TABLE cockpit.ctfd_sync_state (
    source                  text NOT NULL,
    entity                  text NOT NULL,
    checkpoint              bigint NOT NULL CHECK (checkpoint >= 1),
    schema_version          text NOT NULL,
    last_batch_id           uuid NOT NULL,
    last_source_timestamp   timestamptz NOT NULL,
    last_ingested_at        timestamptz NOT NULL,
    PRIMARY KEY (source, entity)
);

CREATE TABLE cockpit.snapshot_runs (
    source          text NOT NULL,
    entity          text NOT NULL,
    snapshot_id     uuid NOT NULL,
    schema_version  text NOT NULL,
    next_chunk      integer NOT NULL DEFAULT 0 CHECK (next_chunk >= 0),
    started_at      timestamptz NOT NULL,
    last_chunk_at   timestamptz NOT NULL,
    completed       boolean NOT NULL DEFAULT false,
    completed_at    timestamptz,
    PRIMARY KEY (source, entity, snapshot_id)
);

CREATE INDEX snapshot_runs_abandoned_idx
    ON cockpit.snapshot_runs (last_chunk_at)
    WHERE completed = false;

CREATE TABLE cockpit.snapshot_members (
    source          text NOT NULL,
    entity          text NOT NULL,
    snapshot_id     uuid NOT NULL,
    source_id       bigint NOT NULL CHECK (source_id >= 1),
    PRIMARY KEY (source, entity, snapshot_id, source_id),
    FOREIGN KEY (source, entity, snapshot_id)
        REFERENCES cockpit.snapshot_runs (source, entity, snapshot_id)
        ON DELETE CASCADE
);

DO $create_entity_tables$
DECLARE
    entity text;
BEGIN
    FOREACH entity IN ARRAY ARRAY[
        'users', 'teams', 'challenges', 'hints', 'awards', 'tags', 'topics',
        'challenge_topics', 'solutions', 'files', 'flags', 'unlocks', 'tracking',
        'notifications', 'pages', 'comments', 'fields', 'field_entries', 'brackets',
        'ratings', 'submissions', 'dynamic_challenge', 'dynamic_docker_challenge',
        'whale_container', 'services'
    ] LOOP
        EXECUTE format(
            'CREATE TABLE cockpit.ctfd_%I (
                source text NOT NULL,
                source_id bigint NOT NULL CHECK (source_id >= 1),
                payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = ''object''),
                source_timestamp timestamptz NOT NULL,
                ingested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
                schema_version text NOT NULL,
                batch_id uuid NOT NULL,
                snapshot_id uuid,
                checkpoint bigint,
                deleted_at timestamptz,
                PRIMARY KEY (source, source_id)
            )',
            entity
        );
        EXECUTE format(
            'CREATE INDEX ctfd_%I_source_time_idx
             ON cockpit.ctfd_%I (source, source_timestamp DESC)
             WHERE deleted_at IS NULL',
            entity, entity
        );
    END LOOP;
END
$create_entity_tables$;

ALTER TABLE cockpit.ctfd_users
    ADD COLUMN username text GENERATED ALWAYS AS (payload ->> 'name') STORED,
    ADD COLUMN email text GENERATED ALWAYS AS (payload ->> 'email') STORED,
    ADD COLUMN affiliation text GENERATED ALWAYS AS (payload ->> 'affiliation') STORED,
    ADD COLUMN country text GENERATED ALWAYS AS (payload ->> 'country') STORED,
    ADD COLUMN team_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'team_id', '')::bigint) STORED,
    ADD COLUMN hidden boolean GENERATED ALWAYS AS (COALESCE((payload ->> 'hidden')::boolean, false)) STORED,
    ADD COLUMN banned boolean GENERATED ALWAYS AS (COALESCE((payload ->> 'banned')::boolean, false)) STORED,
    ADD COLUMN verified boolean GENERATED ALWAYS AS (COALESCE((payload ->> 'verified')::boolean, false)) STORED,
    ADD COLUMN registered_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'created')) STORED;

CREATE INDEX ctfd_users_name_idx ON cockpit.ctfd_users (source, lower(username));
CREATE INDEX ctfd_users_email_idx ON cockpit.ctfd_users (source, lower(email));
CREATE INDEX ctfd_users_team_idx ON cockpit.ctfd_users (source, team_id);

ALTER TABLE cockpit.ctfd_teams
    ADD COLUMN name text GENERATED ALWAYS AS (payload ->> 'name') STORED,
    ADD COLUMN email text GENERATED ALWAYS AS (payload ->> 'email') STORED,
    ADD COLUMN affiliation text GENERATED ALWAYS AS (payload ->> 'affiliation') STORED,
    ADD COLUMN country text GENERATED ALWAYS AS (payload ->> 'country') STORED,
    ADD COLUMN captain_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'captain_id', '')::bigint) STORED,
    ADD COLUMN hidden boolean GENERATED ALWAYS AS (COALESCE((payload ->> 'hidden')::boolean, false)) STORED,
    ADD COLUMN banned boolean GENERATED ALWAYS AS (COALESCE((payload ->> 'banned')::boolean, false)) STORED,
    ADD COLUMN registered_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'created')) STORED;

CREATE INDEX ctfd_teams_name_idx ON cockpit.ctfd_teams (source, lower(name));

ALTER TABLE cockpit.ctfd_challenges
    ADD COLUMN name text GENERATED ALWAYS AS (payload ->> 'name') STORED,
    ADD COLUMN category text GENERATED ALWAYS AS (payload ->> 'category') STORED,
    ADD COLUMN challenge_type text GENERATED ALWAYS AS (payload ->> 'type') STORED,
    ADD COLUMN state text GENERATED ALWAYS AS (payload ->> 'state') STORED,
    ADD COLUMN value integer GENERATED ALWAYS AS (NULLIF(payload ->> 'value', '')::integer) STORED,
    ADD COLUMN max_attempts integer GENERATED ALWAYS AS (NULLIF(payload ->> 'max_attempts', '')::integer) STORED;

CREATE INDEX ctfd_challenges_category_idx ON cockpit.ctfd_challenges (source, category);

ALTER TABLE cockpit.ctfd_submissions
    ADD COLUMN challenge_id bigint GENERATED ALWAYS AS ((payload ->> 'challenge_id')::bigint) STORED,
    ADD COLUMN user_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'user_id', '')::bigint) STORED,
    ADD COLUMN team_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'team_id', '')::bigint) STORED,
    ADD COLUMN source_ip text GENERATED ALWAYS AS (payload ->> 'ip') STORED,
    ADD COLUMN attempted_value text GENERATED ALWAYS AS (payload ->> 'provided') STORED,
    ADD COLUMN result_type text GENERATED ALWAYS AS (payload ->> 'type') STORED,
    ADD COLUMN submitted_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'date')) STORED;

CREATE INDEX ctfd_submissions_challenge_idx
    ON cockpit.ctfd_submissions (source, challenge_id, submitted_at DESC);
CREATE INDEX ctfd_submissions_user_idx
    ON cockpit.ctfd_submissions (source, user_id, submitted_at DESC);
CREATE INDEX ctfd_submissions_team_idx
    ON cockpit.ctfd_submissions (source, team_id, submitted_at DESC);
CREATE INDEX ctfd_submissions_ip_idx
    ON cockpit.ctfd_submissions (source, source_ip, submitted_at DESC);

ALTER TABLE cockpit.ctfd_tracking
    ADD COLUMN event_type text GENERATED ALWAYS AS (payload ->> 'type') STORED,
    ADD COLUMN source_ip text GENERATED ALWAYS AS (payload ->> 'ip') STORED,
    ADD COLUMN target text GENERATED ALWAYS AS (payload ->> 'target') STORED,
    ADD COLUMN user_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'user_id', '')::bigint) STORED,
    ADD COLUMN occurred_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'date')) STORED;

CREATE INDEX ctfd_tracking_user_idx ON cockpit.ctfd_tracking (source, user_id, occurred_at DESC);
CREATE INDEX ctfd_tracking_ip_idx ON cockpit.ctfd_tracking (source, source_ip, occurred_at DESC);

ALTER TABLE cockpit.ctfd_unlocks
    ADD COLUMN user_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'user_id', '')::bigint) STORED,
    ADD COLUMN team_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'team_id', '')::bigint) STORED,
    ADD COLUMN target_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'target', '')::bigint) STORED,
    ADD COLUMN unlock_type text GENERATED ALWAYS AS (payload ->> 'type') STORED,
    ADD COLUMN unlocked_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'date')) STORED;

ALTER TABLE cockpit.ctfd_awards
    ADD COLUMN user_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'user_id', '')::bigint) STORED,
    ADD COLUMN team_id bigint GENERATED ALWAYS AS (NULLIF(payload ->> 'team_id', '')::bigint) STORED,
    ADD COLUMN name text GENERATED ALWAYS AS (payload ->> 'name') STORED,
    ADD COLUMN category text GENERATED ALWAYS AS (payload ->> 'category') STORED,
    ADD COLUMN value integer GENERATED ALWAYS AS (NULLIF(payload ->> 'value', '')::integer) STORED,
    ADD COLUMN awarded_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'date')) STORED;

ALTER TABLE cockpit.ctfd_hints
    ADD COLUMN challenge_id bigint GENERATED ALWAYS AS ((payload ->> 'challenge_id')::bigint) STORED,
    ADD COLUMN title text GENERATED ALWAYS AS (payload ->> 'title') STORED,
    ADD COLUMN cost integer GENERATED ALWAYS AS (NULLIF(payload ->> 'cost', '')::integer) STORED;

ALTER TABLE cockpit.ctfd_ratings
    ADD COLUMN user_id bigint GENERATED ALWAYS AS ((payload ->> 'user_id')::bigint) STORED,
    ADD COLUMN challenge_id bigint GENERATED ALWAYS AS ((payload ->> 'challenge_id')::bigint) STORED,
    ADD COLUMN value integer GENERATED ALWAYS AS (NULLIF(payload ->> 'value', '')::integer) STORED,
    ADD COLUMN rated_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'date')) STORED;

ALTER TABLE cockpit.ctfd_whale_container
    ADD COLUMN user_id bigint GENERATED ALWAYS AS ((payload ->> 'user_id')::bigint) STORED,
    ADD COLUMN challenge_id bigint GENERATED ALWAYS AS ((payload ->> 'challenge_id')::bigint) STORED,
    ADD COLUMN status text GENERATED ALWAYS AS (payload ->> 'status') STORED,
    ADD COLUMN container_uuid text GENERATED ALWAYS AS (payload ->> 'uuid') STORED,
    ADD COLUMN started_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'start_time')) STORED;

CREATE INDEX ctfd_whale_status_idx
    ON cockpit.ctfd_whale_container (source, status, started_at DESC);

ALTER TABLE cockpit.ctfd_services
    ADD COLUMN task_id text GENERATED ALWAYS AS (payload ->> 'task_id') STORED,
    ADD COLUMN project_name text GENERATED ALWAYS AS (payload ->> 'project_name') STORED,
    ADD COLUMN status text GENERATED ALWAYS AS (payload ->> 'status') STORED,
    ADD COLUMN errored boolean GENERATED ALWAYS AS (COALESCE((payload ->> 'errored')::boolean, false)) STORED,
    ADD COLUMN created_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'created')) STORED,
    ADD COLUMN built_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'built')) STORED,
    ADD COLUMN pushed_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'pushed')) STORED,
    ADD COLUMN deployed_at timestamptz GENERATED ALWAYS AS (cockpit.utc_timestamptz(payload ->> 'deployed')) STORED;

CREATE VIEW cockpit.live_submission_feed AS
SELECT
    submission.source,
    submission.source_id AS submission_id,
    submission.submitted_at,
    submission.ingested_at,
    submission.result_type,
    submission.attempted_value,
    submission.source_ip,
    submission.user_id,
    users.username,
    users.email,
    submission.team_id,
    teams.name AS team_name,
    submission.challenge_id,
    challenges.name AS challenge_name,
    challenges.category
FROM cockpit.ctfd_submissions AS submission
LEFT JOIN cockpit.ctfd_users AS users
  ON users.source = submission.source
 AND users.source_id = submission.user_id
 AND users.deleted_at IS NULL
LEFT JOIN cockpit.ctfd_teams AS teams
  ON teams.source = submission.source
 AND teams.source_id = submission.team_id
 AND teams.deleted_at IS NULL
LEFT JOIN cockpit.ctfd_challenges AS challenges
  ON challenges.source = submission.source
 AND challenges.source_id = submission.challenge_id
 AND challenges.deleted_at IS NULL
WHERE submission.deleted_at IS NULL;

ALTER DEFAULT PRIVILEGES FOR ROLE ctfd_cockpit_migrator IN SCHEMA cockpit
    GRANT SELECT, INSERT, UPDATE ON TABLES TO ctfd_cockpit_ingest;
ALTER DEFAULT PRIVILEGES FOR ROLE ctfd_cockpit_migrator IN SCHEMA cockpit
    GRANT SELECT ON TABLES TO ctfd_cockpit_grafana;

GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA cockpit TO ctfd_cockpit_ingest;
GRANT DELETE ON cockpit.snapshot_runs, cockpit.snapshot_members TO ctfd_cockpit_ingest;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
    ON ALL TABLES IN SCHEMA cockpit FROM ctfd_cockpit_grafana;
GRANT SELECT ON ALL TABLES IN SCHEMA cockpit TO ctfd_cockpit_grafana;
REVOKE ALL ON cockpit.schema_migrations FROM ctfd_cockpit_ingest;
GRANT SELECT ON cockpit.schema_migrations TO ctfd_cockpit_ingest, ctfd_cockpit_grafana;
