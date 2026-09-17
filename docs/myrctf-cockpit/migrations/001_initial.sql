BEGIN;

SET LOCAL timezone = 'UTC';

CREATE SCHEMA IF NOT EXISTS cockpit AUTHORIZATION ctfd_cockpit_migrator;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA cockpit TO ctfd_cockpit_ingest, ctfd_cockpit_grafana;

CREATE TABLE cockpit.schema_migrations (
    version             integer PRIMARY KEY,
    applied_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    checksum            text NOT NULL
);

CREATE TABLE cockpit.ingest_batches (
    source_instance     text NOT NULL,
    stream              text NOT NULL,
    batch_id            uuid NOT NULL,
    schema_version      text NOT NULL,
    sequence            numeric(20, 0) NOT NULL CHECK (sequence >= 0),
    checkpoint          numeric(20, 0) NOT NULL CHECK (checkpoint >= 0),
    source_event_time   timestamptz NOT NULL,
    record_count        integer NOT NULL CHECK (record_count BETWEEN 0 AND 5000),
    request_sha256      bytea NOT NULL CHECK (octet_length(request_sha256) = 32),
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (source_instance, batch_id),
    UNIQUE (source_instance, stream, sequence),
    UNIQUE (source_instance, stream, checkpoint)
);

CREATE TABLE cockpit.ctfd_sync_state (
    source_instance             text NOT NULL,
    stream                      text NOT NULL,
    schema_version              text NOT NULL,
    last_batch_id               uuid,
    last_sequence               numeric(20, 0) NOT NULL DEFAULT 0 CHECK (last_sequence >= 0),
    durable_checkpoint          numeric(20, 0) NOT NULL DEFAULT 0 CHECK (durable_checkpoint >= 0),
    last_source_event_time      timestamptz,
    last_ingested_at            timestamptz,
    updated_at                  timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (source_instance, stream)
);

CREATE TABLE cockpit.ctfd_users (
    source_instance     text NOT NULL,
    user_id             bigint NOT NULL CHECK (user_id >= 0),
    username            text NOT NULL,
    email               text,
    oauth_id            text,
    name                text,
    website             text,
    affiliation         text,
    country             text,
    bracket             text,
    user_type           text,
    team_id             bigint,
    verified            boolean NOT NULL DEFAULT false,
    hidden              boolean NOT NULL DEFAULT false,
    banned              boolean NOT NULL DEFAULT false,
    custom_fields       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom_fields) = 'object'),
    registered_at       timestamptz,
    last_active_at      timestamptz,
    source_updated_at   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, user_id)
);

CREATE INDEX ctfd_users_team_idx ON cockpit.ctfd_users (source_instance, team_id);
CREATE INDEX ctfd_users_email_lower_idx ON cockpit.ctfd_users (source_instance, lower(email));
CREATE INDEX ctfd_users_activity_idx ON cockpit.ctfd_users (source_instance, last_active_at DESC);

CREATE TABLE cockpit.ctfd_teams (
    source_instance     text NOT NULL,
    team_id             bigint NOT NULL CHECK (team_id >= 0),
    name                text NOT NULL,
    email               text,
    captain_id          bigint,
    website             text,
    affiliation         text,
    country             text,
    bracket             text,
    team_type           text,
    hidden              boolean NOT NULL DEFAULT false,
    banned              boolean NOT NULL DEFAULT false,
    custom_fields       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(custom_fields) = 'object'),
    registered_at       timestamptz,
    last_active_at      timestamptz,
    source_updated_at   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, team_id)
);

CREATE INDEX ctfd_teams_activity_idx ON cockpit.ctfd_teams (source_instance, last_active_at DESC);

CREATE TABLE cockpit.ctfd_team_members (
    source_instance     text NOT NULL,
    team_id             bigint NOT NULL CHECK (team_id >= 0),
    user_id             bigint NOT NULL CHECK (user_id >= 0),
    source_id           bigint,
    joined_at           timestamptz,
    source_updated_at   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, team_id, user_id),
    UNIQUE NULLS NOT DISTINCT (source_instance, source_id)
);

CREATE INDEX ctfd_team_members_user_idx ON cockpit.ctfd_team_members (source_instance, user_id);

CREATE TABLE cockpit.ctfd_challenges (
    source_instance     text NOT NULL,
    challenge_id        bigint NOT NULL CHECK (challenge_id >= 0),
    name                text NOT NULL,
    category            text,
    description         text,
    connection_info     text,
    challenge_type      text NOT NULL,
    state               text,
    value               integer,
    initial_value       integer,
    minimum_value       integer,
    decay               integer,
    max_attempts        integer,
    requirements        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(requirements) = 'object'),
    created_at          timestamptz,
    source_updated_at   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, challenge_id)
);

CREATE INDEX ctfd_challenges_category_idx ON cockpit.ctfd_challenges (source_instance, category);

CREATE TABLE cockpit.ctfd_challenge_tags (
    source_instance     text NOT NULL,
    tag_id              bigint NOT NULL CHECK (tag_id >= 0),
    challenge_id        bigint NOT NULL CHECK (challenge_id >= 0),
    value               text NOT NULL,
    source_updated_at   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, tag_id)
);

CREATE INDEX ctfd_challenge_tags_challenge_idx ON cockpit.ctfd_challenge_tags (source_instance, challenge_id);

CREATE TABLE cockpit.ctfd_hints (
    source_instance     text NOT NULL,
    hint_id             bigint NOT NULL CHECK (hint_id >= 0),
    challenge_id        bigint NOT NULL CHECK (challenge_id >= 0),
    content             text,
    cost                integer,
    hint_type           text,
    requirements        jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(requirements) = 'object'),
    source_updated_at   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, hint_id)
);

CREATE INDEX ctfd_hints_challenge_idx ON cockpit.ctfd_hints (source_instance, challenge_id);

CREATE TABLE cockpit.ctfd_pages (
    source_instance     text NOT NULL,
    page_id             bigint NOT NULL CHECK (page_id >= 0),
    title               text,
    route               text,
    content             text,
    draft               boolean NOT NULL DEFAULT false,
    hidden              boolean NOT NULL DEFAULT false,
    auth_required       boolean NOT NULL DEFAULT false,
    source_updated_at   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, page_id)
);

CREATE TABLE cockpit.ctfd_challenge_instances (
    source_instance     text NOT NULL,
    instance_id         text NOT NULL,
    challenge_id        bigint,
    user_id             bigint,
    team_id             bigint,
    state               text NOT NULL,
    failure_class       text,
    connection_info     text,
    created_at          timestamptz,
    started_at          timestamptz,
    expires_at          timestamptz,
    stopped_at          timestamptz,
    source_updated_at   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, instance_id)
);

CREATE INDEX ctfd_instances_challenge_state_idx
    ON cockpit.ctfd_challenge_instances (source_instance, challenge_id, state);
CREATE INDEX ctfd_instances_expiry_idx
    ON cockpit.ctfd_challenge_instances (source_instance, expires_at) WHERE deleted_at IS NULL;

-- Immutable source events. Tombstones may set deleted_at but event content is
-- never overwritten after the first successful insert.
CREATE TABLE cockpit.ctfd_submissions (
    source_instance     text NOT NULL,
    source_table        text NOT NULL,
    source_id           bigint NOT NULL CHECK (source_id >= 0),
    attempted_value     text,
    result_type         text NOT NULL,
    submission_type     text,
    source_event_time   timestamptz NOT NULL,
    user_id             bigint,
    team_id             bigint,
    challenge_id        bigint NOT NULL,
    source_ip           inet,
    points              integer,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, source_table, source_id)
);

CREATE INDEX ctfd_submissions_time_idx ON cockpit.ctfd_submissions (source_instance, source_event_time DESC);
CREATE INDEX ctfd_submissions_challenge_idx ON cockpit.ctfd_submissions (source_instance, challenge_id, source_event_time DESC);
CREATE INDEX ctfd_submissions_user_idx ON cockpit.ctfd_submissions (source_instance, user_id, source_event_time DESC);
CREATE INDEX ctfd_submissions_team_idx ON cockpit.ctfd_submissions (source_instance, team_id, source_event_time DESC);
CREATE INDEX ctfd_submissions_ip_idx ON cockpit.ctfd_submissions (source_instance, source_ip, source_event_time DESC);

CREATE TABLE cockpit.ctfd_solves (
    source_instance     text NOT NULL,
    source_table        text NOT NULL,
    source_id           bigint NOT NULL CHECK (source_id >= 0),
    submission_id       bigint,
    challenge_id        bigint NOT NULL,
    user_id             bigint,
    team_id             bigint,
    source_ip           inet,
    points              integer,
    source_event_time   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, source_table, source_id)
);

CREATE INDEX ctfd_solves_challenge_time_idx ON cockpit.ctfd_solves (source_instance, challenge_id, source_event_time);
CREATE INDEX ctfd_solves_team_time_idx ON cockpit.ctfd_solves (source_instance, team_id, source_event_time);

CREATE TABLE cockpit.ctfd_awards (
    source_instance     text NOT NULL,
    source_table        text NOT NULL,
    source_id           bigint NOT NULL CHECK (source_id >= 0),
    user_id             bigint,
    team_id             bigint,
    name                text,
    description         text,
    category            text,
    value               integer NOT NULL,
    icon                text,
    source_event_time   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, source_table, source_id)
);

CREATE INDEX ctfd_awards_team_time_idx ON cockpit.ctfd_awards (source_instance, team_id, source_event_time);

CREATE TABLE cockpit.ctfd_hint_unlocks (
    source_instance     text NOT NULL,
    source_table        text NOT NULL,
    source_id           bigint NOT NULL CHECK (source_id >= 0),
    hint_id             bigint NOT NULL,
    user_id             bigint,
    team_id             bigint,
    cost                integer,
    source_event_time   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, source_table, source_id)
);

CREATE INDEX ctfd_hint_unlocks_hint_time_idx ON cockpit.ctfd_hint_unlocks (source_instance, hint_id, source_event_time);

CREATE TABLE cockpit.ctfd_tracking_events (
    source_instance     text NOT NULL,
    source_table        text NOT NULL,
    source_id           bigint NOT NULL CHECK (source_id >= 0),
    event_type          text NOT NULL,
    user_id             bigint,
    team_id             bigint,
    source_ip           inet,
    path                text,
    source_event_time   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, source_table, source_id)
);

CREATE INDEX ctfd_tracking_user_time_idx ON cockpit.ctfd_tracking_events (source_instance, user_id, source_event_time DESC);
CREATE INDEX ctfd_tracking_ip_time_idx ON cockpit.ctfd_tracking_events (source_instance, source_ip, source_event_time DESC);

CREATE TABLE cockpit.ctfd_notifications (
    source_instance     text NOT NULL,
    source_table        text NOT NULL,
    source_id           bigint NOT NULL CHECK (source_id >= 0),
    title               text,
    content             text,
    notification_type   text,
    sound               boolean,
    user_id             bigint,
    team_id             bigint,
    source_event_time   timestamptz NOT NULL,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, source_table, source_id)
);

CREATE INDEX ctfd_notifications_time_idx ON cockpit.ctfd_notifications (source_instance, source_event_time DESC);

CREATE TABLE cockpit.ctfd_scoreboard_snapshots (
    source_instance     text NOT NULL,
    snapshot_key        text NOT NULL,
    source_event_time   timestamptz NOT NULL,
    team_id             bigint NOT NULL,
    rank                integer NOT NULL CHECK (rank > 0),
    score               integer NOT NULL,
    bracket             text,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    deleted_at          timestamptz,
    PRIMARY KEY (source_instance, snapshot_key, team_id)
);

CREATE INDEX ctfd_scoreboard_team_time_idx
    ON cockpit.ctfd_scoreboard_snapshots (source_instance, team_id, source_event_time DESC);
CREATE INDEX ctfd_scoreboard_time_rank_idx
    ON cockpit.ctfd_scoreboard_snapshots (source_instance, source_event_time DESC, rank);

CREATE TABLE cockpit.ctfd_tombstones (
    source_instance     text NOT NULL,
    source_table        text NOT NULL,
    source_id           text NOT NULL,
    source_event_time   timestamptz NOT NULL,
    reason              text,
    source_checkpoint   numeric(20, 0) NOT NULL CHECK (source_checkpoint >= 0),
    schema_version      text NOT NULL,
    batch_id            uuid NOT NULL,
    ingested_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (source_instance, source_table, source_id)
);

CREATE INDEX ctfd_tombstones_time_idx ON cockpit.ctfd_tombstones (source_instance, source_event_time DESC);

ALTER DEFAULT PRIVILEGES FOR ROLE ctfd_cockpit_migrator IN SCHEMA cockpit
    GRANT SELECT, INSERT ON TABLES TO ctfd_cockpit_ingest;
ALTER DEFAULT PRIVILEGES FOR ROLE ctfd_cockpit_migrator IN SCHEMA cockpit
    GRANT USAGE, SELECT ON SEQUENCES TO ctfd_cockpit_ingest;
ALTER DEFAULT PRIVILEGES FOR ROLE ctfd_cockpit_migrator IN SCHEMA cockpit
    GRANT SELECT ON TABLES TO ctfd_cockpit_grafana;

GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA cockpit TO ctfd_cockpit_ingest;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA cockpit TO ctfd_cockpit_ingest;
GRANT SELECT ON ALL TABLES IN SCHEMA cockpit TO ctfd_cockpit_grafana;

REVOKE INSERT ON cockpit.schema_migrations FROM ctfd_cockpit_ingest;
GRANT UPDATE ON cockpit.ctfd_sync_state TO ctfd_cockpit_ingest;
GRANT UPDATE ON
    cockpit.ctfd_users,
    cockpit.ctfd_teams,
    cockpit.ctfd_team_members,
    cockpit.ctfd_challenges,
    cockpit.ctfd_challenge_tags,
    cockpit.ctfd_hints,
    cockpit.ctfd_pages,
    cockpit.ctfd_challenge_instances
TO ctfd_cockpit_ingest;
GRANT UPDATE (deleted_at) ON
    cockpit.ctfd_submissions,
    cockpit.ctfd_solves,
    cockpit.ctfd_awards,
    cockpit.ctfd_hint_unlocks,
    cockpit.ctfd_tracking_events,
    cockpit.ctfd_notifications,
    cockpit.ctfd_scoreboard_snapshots
TO ctfd_cockpit_ingest;
REVOKE DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA cockpit FROM ctfd_cockpit_ingest;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA cockpit FROM ctfd_cockpit_grafana;

COMMIT;
