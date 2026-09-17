from prometheus_client import Counter, Gauge, Histogram


REQUESTS = Counter(
    "ctfd_cockpit_ingest_requests_total",
    "Cockpit ingestion HTTP requests",
    ("endpoint", "result"),
)
RECORDS = Counter(
    "ctfd_cockpit_ingest_records_total",
    "Cockpit records committed",
    ("entity", "operation"),
)
REJECTIONS = Counter(
    "ctfd_cockpit_ingest_rejected_batches_total",
    "Cockpit batches rejected before commit",
    ("endpoint", "reason"),
)
DB_ERRORS = Counter(
    "ctfd_cockpit_ingest_db_errors_total",
    "Cockpit database errors",
    ("operation",),
)
DURATION = Histogram(
    "ctfd_cockpit_ingest_request_duration_seconds",
    "Cockpit ingestion request duration",
    ("endpoint",),
)
LAST_SUCCESS = Gauge(
    "ctfd_cockpit_ingest_last_success_timestamp_seconds",
    "Last successful Cockpit commit",
    ("source", "endpoint"),
)
CHECKPOINT = Gauge(
    "ctfd_cockpit_ingest_checkpoint",
    "Highest durably committed source checkpoint",
    ("source", "entity"),
)
REPLICATION_LAG = Gauge(
    "ctfd_cockpit_ingest_replication_lag_seconds",
    "Seconds between source time and durable ingestion",
    ("source", "entity"),
)
