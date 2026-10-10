# Terraformコード生成ベンチマーク結果

3モデル(Claude Haiku 4.5 / Sonnet 5.5 / Haiku 5.5)に同一プロンプトでTerraformコードを生成させ、`terraform fmt`/`validate`、tflint、checkov、要件カバレッジ、セキュリティアンチパターンの5軸で客観的に評価した。

## 総合スコア (100点満点、算出方法は末尾参照)

| タスク | Claude Haiku 4.5 | Claude Sonnet 5.5 | Claude Haiku 5.5 |
| --- | --- | --- | --- |
| タスク1: シンプル (S3) | 84.2 | 87.2 | 87.2 |
| タスク2: 中程度 (VPC+EC2) | 68.4 | 88.4 | 86.9 |
| タスク3: 複雑 (ALB+ASG+RDS+IAM) | 76.1 | 87.8 | 79.6 |
| **平均** | **76.2** | **87.8** | **84.6** |

## 詳細結果

### タスク1: シンプル (S3)

| モデル | fmt | validate | tflint issues | checkov pass/fail | 要件カバレッジ | セキュリティ懸念 | 行数 | ファイル数 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Haiku 4.5 | OK | OK | 1 | 11/5 | 8/8 | - | 65 | 1 |
| Claude Sonnet 5.5 | OK | OK | 0 | 11/5 | 8/8 | - | 79 | 1 |
| Claude Haiku 5.5 | OK | OK | 0 | 11/5 | 8/8 | - | 64 | 4 |


### タスク2: 中程度 (VPC+EC2)

| モデル | fmt | validate | tflint issues | checkov pass/fail | 要件カバレッジ | セキュリティ懸念 | 行数 | ファイル数 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Haiku 4.5 | NG | OK | 1 | 10/12 | 11/11 | - | 176 | 1 |
| Claude Sonnet 5.5 | OK | OK | 0 | 25/9 | 11/11 | - | 228 | 1 |
| Claude Haiku 5.5 | OK | OK | 0 | 23/11 | 11/11 | - | 208 | 1 |


### タスク3: 複雑 (ALB+ASG+RDS+IAM)

| モデル | fmt | validate | tflint issues | checkov pass/fail | 要件カバレッジ | セキュリティ懸念 | 行数 | ファイル数 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Haiku 4.5 | NG | OK | 0 | 51/28 | 16/16 | - | 499 | 1 |
| Claude Sonnet 5.5 | OK | OK | 1 | 99/20 | 16/16 | - | 552 | 1 |
| Claude Haiku 5.5 | NG | OK | 0 | 76/21 | 16/16 | - | 563 | 1 |


## スコア算出方法

- `terraform fmt -check` 通過: 10点
- `terraform validate` 通過: 25点
- tflint指摘0件: 15点(1件につき-3点、最大-15点)
- checkov通過率 × 25点
- 要件カバレッジ(正規表現による必須リソース検出) × 20点
- セキュリティアンチパターン(SSH全開放・ハードコードされたパスワード等) 1件につき-5点
