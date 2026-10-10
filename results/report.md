# Terraformコード生成ベンチマーク結果

3モデル(Claude Haiku 4.5 / Sonnet 5.5 / Haiku 5.5)に同一プロンプトでTerraformコードを生成させ、`terraform fmt`/`validate`、tflint、checkov、要件カバレッジ、コーディング規約準拠、セキュリティアンチパターンの6軸で客観的に評価した。

## 総合スコア (100点満点、算出方法は末尾参照)

| タスク | Claude Haiku 4.5 | Claude Sonnet 5.5 | Claude Haiku 5.5 |
| --- | --- | --- | --- |
| タスク1: シンプル (S3) | 81.8 | 83.8 | 83.8 |
| タスク2: 中程度 (VPC+EC2) | 66.2 | 83.9 | 82.7 |
| タスク3: 複雑 (ALB+ASG+RDS+IAM) | 72.2 | 84.0 | 75.0 |
| **平均** | **73.4** | **83.9** | **80.5** |

## 詳細結果

### タスク1: シンプル (S3)

| モデル | fmt | validate | tflint issues | checkov pass/fail | 要件カバレッジ | 規約準拠 | セキュリティ懸念 | 行数 | ファイル数 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Haiku 4.5 | OK | OK | 1 | 11/5 | 8/8 | 16/16 | - | 65 | 1 |
| Claude Sonnet 5.5 | OK | OK | 0 | 11/5 | 8/8 | 16/16 | - | 79 | 1 |
| Claude Haiku 5.5 | OK | OK | 0 | 11/5 | 8/8 | 16/16 | - | 64 | 4 |


### タスク2: 中程度 (VPC+EC2)

| モデル | fmt | validate | tflint issues | checkov pass/fail | 要件カバレッジ | 規約準拠 | セキュリティ懸念 | 行数 | ファイル数 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Haiku 4.5 | NG | OK | 1 | 10/12 | 11/11 | 32/34 | - | 176 | 1 |
| Claude Sonnet 5.5 | OK | OK | 0 | 25/9 | 11/11 | 36/38 | - | 228 | 1 |
| Claude Haiku 5.5 | OK | OK | 0 | 23/11 | 11/11 | 36/38 | - | 208 | 1 |

- **Claude Haiku 4.5**: 規約違反: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている
- **Claude Sonnet 5.5**: 規約違反: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている
- **Claude Haiku 5.5**: 規約違反: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている

### タスク3: 複雑 (ALB+ASG+RDS+IAM)

| モデル | fmt | validate | tflint issues | checkov pass/fail | 要件カバレッジ | 規約準拠 | セキュリティ懸念 | 行数 | ファイル数 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Haiku 4.5 | NG | OK | 0 | 51/28 | 16/16 | 76/80 | - | 499 | 1 |
| Claude Sonnet 5.5 | OK | OK | 1 | 99/20 | 16/16 | 95/99 | - | 552 | 1 |
| Claude Haiku 5.5 | NG | OK | 0 | 76/21 | 16/16 | 90/94 | - | 563 | 1 |

- **Claude Haiku 4.5**: 規約違反: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_subnet.private" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.private" はcountではなくfor_eachを使っている
- **Claude Sonnet 5.5**: 規約違反: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_subnet.private" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.private" はcountではなくfor_eachを使っている
- **Claude Haiku 5.5**: 規約違反: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_subnet.private" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.private" はcountではなくfor_eachを使っている

## コーディング規約を明示した場合の準拠率

プロンプトに規約を書かなかった場合(規約なし)と、タスク末尾に明示的なコーディング規約を追記した場合(規約あり)で、準拠率がどう変わるかを比較した。

| タスク | モデル | 規約なし | 規約あり |
| --- | --- | --- | --- |
| タスク1: シンプル (S3) | Claude Haiku 4.5 | 16/16 | 16/16 |
| タスク1: シンプル (S3) | Claude Sonnet 5.5 | 16/16 | 16/16 |
| タスク1: シンプル (S3) | Claude Haiku 5.5 | 16/16 | 16/16 |
| タスク2: 中程度 (VPC+EC2) | Claude Haiku 4.5 | 32/34 | 32/32 |
| タスク2: 中程度 (VPC+EC2) | Claude Sonnet 5.5 | 36/38 | 36/36 |
| タスク2: 中程度 (VPC+EC2) | Claude Haiku 5.5 | 36/38 | 41/41 |
| タスク3: 複雑 (ALB+ASG+RDS+IAM) | Claude Haiku 4.5 | 76/80 | 82/82 |
| タスク3: 複雑 (ALB+ASG+RDS+IAM) | Claude Sonnet 5.5 | 95/99 | 95/95 |
| タスク3: 複雑 (ALB+ASG+RDS+IAM) | Claude Haiku 5.5 | 90/94 | 89/89 |

### 規約なしで検出された違反の内訳

- **Claude Haiku 4.5 / タスク2: 中程度 (VPC+EC2)**: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている
- **Claude Sonnet 5.5 / タスク2: 中程度 (VPC+EC2)**: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている
- **Claude Haiku 5.5 / タスク2: 中程度 (VPC+EC2)**: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている
- **Claude Haiku 4.5 / タスク3: 複雑 (ALB+ASG+RDS+IAM)**: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_subnet.private" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.private" はcountではなくfor_eachを使っている
- **Claude Sonnet 5.5 / タスク3: 複雑 (ALB+ASG+RDS+IAM)**: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_subnet.private" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.private" はcountではなくfor_eachを使っている
- **Claude Haiku 5.5 / タスク3: 複雑 (ALB+ASG+RDS+IAM)**: resource "aws_subnet.public" はcountではなくfor_eachを使っている, resource "aws_subnet.private" はcountではなくfor_eachを使っている, resource "aws_route_table_association.public" はcountではなくfor_eachを使っている, resource "aws_route_table_association.private" はcountではなくfor_eachを使っている

## スコア算出方法

- `terraform fmt -check` 通過: 10点
- `terraform validate` 通過: 20点
- tflint指摘0件: 10点(1件につき-2点、最大-10点)
- checkov通過率 × 20点
- 要件カバレッジ(正規表現による必須リソース検出) × 15点
- コーディング規約準拠率(variable/outputのtype・description記載、snake_case命名、同一リソースタイプが複数ある場合に`this`を使わない) × 15点
- セキュリティアンチパターン(SSH全開放・ハードコードされたパスワード等) 1件につき-5点
