# r8 unit 2：受付の保存参加

core `16e6fcb2…` のr8 unit1に対するunit2修正版と組み合わせる。
`PHRONOMY_PATH`にそのcheckoutを指定する。API事前確認で`atomic`とAgent受付操作を検査する。

通常アプリのinvoke／Team／Handoffの使用法は変更しない。coreが親予約の検証と子受付の保存参加を組み立てる。

- SQLite／PostgreSQLの共通試験に、受付、先行取消、Agent CAS失敗によるrollback、外側savepoint、受付済みHandoff対象への取消の5件を追加した。
- PostgreSQLには、取消が先の場合、受付が先の場合、Handoffの不在観測後に受付が確定する場合の3件の並行試験を追加した。`pg_blocking_pids`で実際のロック待ちを確認する。
- workflowの同名core branch checkoutを維持し、共通試験ファイルの変更を起動条件へ追加した。core branchを先にpushし、examples側にも同じbranch名を用いる。
- これらのDB backendはStorage::Backendを継承するため、新しい`transaction_open?`は共通実装を使用する。

ローカルの実PostgreSQL検証には`PHRONOMY_POSTGRES_URL`を設定して`scripts/verify_postgresql_persistence.sh`を実行する。通常のoffline検証にはPostgreSQLの実行は含まれない。mainへの取込みはcoreを先、examplesを後とする。
