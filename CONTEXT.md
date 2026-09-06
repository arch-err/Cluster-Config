# Cluster-Config language

Terms used to distinguish repository maintenance from changes to the running system.

## Language

**Repository alignment**: Bringing documentation and repository organization into agreement with the intended configuration. It does not include software upgrades.

**Production baseline**: The configuration on which the currently running system is based. It is distinct from a verified inventory of live resources.

**Legacy archive**: A preserved historical configuration that is kept for reference and recovery, rather than ongoing maintenance.

**Retained service**: A service whose configuration remains available although it is disabled. Retention of configuration does not establish that its data still exists or that it can be safely re-enabled.

**State-preserving refactor**: A change to repository organization that preserves the deployed resource definitions and behavior. Any exception requires J’s explicit approval.

**Zero-diff gate**: A requirement that the proposed configuration has no unapproved differences from the live baseline before any synchronization. Hidden differences and comparison failures do not satisfy the gate.
