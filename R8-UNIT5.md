# r8 unit 5: VectorStore and Embeddings contracts

Apply this examples update together with the core r8 unit 5 package. Select the
updated core with an absolute `PHRONOMY_PATH`, update the bundles using
`scripts/update_phronomy.sh`, then run the API preflights and example specs.
The published gem and a unit 4 checkout do not contain the new contracts.

| Previous namespace | Current namespace |
| --- | --- |
| `Phronomy::VectorStore::Embeddings` | `Phronomy::Embeddings` |
| `Phronomy::VectorStore::Loader` | `Phronomy::Documents::Loader` |
| `Phronomy::VectorStore::Splitter` | `Phronomy::Documents::Splitter` |

Example 14 uses the independent document utilities. Example 24 now implements
the protected `perform_embed` provider hook and inherits the validated public
`embed` operation. Public VectorStore calls remain `add`, `search`, `remove`,
`clear` and `size`; custom storage backends implement protected `perform_*` hooks.
Old-name compatibility aliases are not provided.

The common contract rejects malformed vectors, non-String ids and invalid result
shapes. RubyLLM embedding failures are translated to
`Phronomy::Embeddings::TransportError` with their original exception as `cause`.
See the core `docs/migrations/r8-unit5.md` for exact input and result guarantees.

```sh
python3 scripts/verify_current_api.py
bundle exec ruby scripts/assert_composition_api.rb
bundle exec rspec
```

This unit does not change stored Agent/MultiAgent/Workflow records or the neutral
SQL Storage SPI. No data migration command is required. Real VectorStore services
and embedding providers still need deployment-specific acceptance verification.
