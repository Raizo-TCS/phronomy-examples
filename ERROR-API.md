# Error API migration (DX05-A)

Phronomy 0.29.0 includes these DX05-A error APIs. The default bundles and CI use
the published gem. For local framework development, select an explicit checkout
with `PHRONOMY_PATH` as described in the root README.

* Examples 09/15 catch AgentNotFoundError only around the target Agent load and
  check agent_id. Transcript/clear/summary failures no longer clear the session
  as if the Agent were absent. Example 14 uses the same rule for create-on-absence.
* A busy Team is MultiAgent::TeamBusyError. An Agent owned by coordination
  history is still AgentBusyError. SQL concurrency tests preserve this distinction.
* Fresh-pool SQL tests verify the optional nested cause diagnostic as well as
  the existing class/message/code. Recovery uses generic Phronomy::Error, not
  constantization of a saved class name. Old and unknown codes remain readable.
* No SQL schema, table, migration version or Storage backend behavior changes.
* The released 0.28.0 gem does not include these error APIs. All seven bundle
  lockfiles now select Phronomy 0.29.0 from RubyGems.

Run root tests, both SQL suites/reload demos, Rails 09/15 history verification and
`verify_examples.sh` against the same released core version. Root controller tests use
Rails plumbing doubles; they do not replace real Rails boot/controller/view tests.
DX05-C now uses existing result composition in example 14; see
[its application migration](docs/dx05-review-composition.md). DX05-B uses the existing
M91 delivery errors in example 20; see [notification delivery](docs/dx05-notification-delivery.md).
Listener failures retain the delivery error as the cause of `StreamCallbackError`.
Successful persistence is not reclassified as failure by a final notification error.
DX05-D/E build on this migration. The core error API changes described here are DX05-A.
