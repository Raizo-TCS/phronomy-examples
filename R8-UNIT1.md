# r8第1適用版に対応するexamples

この変更はcore `653e255a` に対するr8第1適用版と組み合わせる。coreのリリース番号は変更していないため、検証時は次のように明示的にcheckoutを選ぶ。

```bash
export PHRONOMY_PATH=/absolute/path/to/phronomy
bundle install
(cd 30_sqlite_persistence && bundle install)
bash scripts/verify_offline.sh
```

PromptTemplateとbefore_llm_inputの値は `Phronomy::Context` 所属となる。Toolの公開入口は `Phronomy::Tool::Base`。旧Agent内の別名は残さない。

preflightはr8第1適用版のAPIを確認する。標準gemの既存バージョンだけを選んでも新しいAPIが存在するとは限らない。SQLite検証にはGemfileのRuby要件を満たす環境が必要である。PostgreSQLサーバーと実LLMへの接続はoffline検証に含まない。
