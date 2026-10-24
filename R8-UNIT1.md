# Examples for r8 unit 1

Use this change together with the first r8 implementation unit based on core `653e255a`. The core release number has not changed, so explicitly select the checkout during verification:

```bash
export PHRONOMY_PATH=/absolute/path/to/phronomy
bundle install
(cd 30_sqlite_persistence && bundle install)
bash scripts/verify_offline.sh
```

PromptTemplate and before_llm_input values now belong to `Phronomy::Context`. The public Tool entry point is `Phronomy::Tool::Base`. The old aliases under Agent are not retained.

Preflight checks the APIs introduced in r8 unit 1. Selecting an existing published gem version alone does not ensure that these new APIs are available. SQLite verification requires an environment satisfying the Gemfile's Ruby requirement. Offline verification does not include connections to a PostgreSQL server or a live LLM.
