# claude-haiku-terraform-benchmark

Claude Haiku 5.5 がリリースされた。今までTerraformのコーディングは Sonnet などのモデルを使用してきたが、Terraformのコーディングはそこまで難しくない。Haiku 5.5 なら十分品質の高いコードが生成出来るのではないかと考えている。

この仮説を検証するため、同一の要件(コーディング規約を含む)を Claude Haiku 4.5 / Claude Sonnet 5.5 / Claude Haiku 5.5 の3モデルに与えてTerraformコードを生成させ、客観的な指標でコード品質・生成時間・コストを比較する。

## 結果

**[results/report.md](results/report.md)** に比較レポートをまとめている。要点:

- 全モデル・全タスクで `terraform validate` は通過し、要件カバレッジ・コーディング規約準拠率はほぼ100%だった
- Haiku 5.5 は平均スコアで Sonnet 5.5 とほぼ同等(3回平均 82.5 vs 83.1。回ごとの差はタスク3の `terraform fmt` 通過有無で入れ替わる)
- Haiku 4.5 は複雑なタスクで `terraform fmt` の崩れが見られ、平均スコアは3モデル中最も低い(3回平均 75.1)
- コストでは Haiku 5.5 が圧倒的に優位で、Sonnet 5.5の約1/13〜1/17。生成時間は必ずしも速くない

## 検証方法

1. 3段階の複雑さを持つAWS Terraformタスクを用意する([tasks/](tasks/))。各タスクのプロンプトには最初からコーディング規約(snake_case命名、`for_each`優先など)を含める
   - タスク1: S3バケット単体(シンプル)
   - タスク2: VPC + EC2 + セキュリティグループ(中程度)
   - タスク3: ALB + ASG + RDS + IAM(複雑)
2. Amazon Bedrock経由で3モデルに同一プロンプトを与え、コードを生成する([scripts/generate.py](scripts/generate.py))。生成時間と入出力トークン数も記録する
3. 生成されたコードを6つの客観的指標で採点する([scripts/evaluate.py](scripts/evaluate.py))
   - `terraform fmt -check`: フォーマット規約準拠
   - `terraform validate`: 構文・設定の妥当性
   - [tflint](https://github.com/terraform-linters/tflint): Terraformベストプラクティス違反
   - [checkov](https://www.checkov.io/): セキュリティ・コンプライアンスのポリシー違反
   - 要件カバレッジ: タスクで要求した必須リソースが実装されているか(正規表現マッチ)
   - コーディング規約準拠率: snake_case命名、`variable`/`output`のdescription記載、`for_each`優先などプロンプトで明示した規約への準拠
   - (参考指標)セキュリティアンチパターン: SSH全開放・認証情報のハードコードなどの簡易検出
4. 各指標を重み付けしてスコア化し、生成時間・トークン数・コストと合わせてレポートを生成する([scripts/report.py](scripts/report.py))

## 使用モデル (Amazon Bedrock, 推論プロファイル)

| 表記 | モデルID |
| --- | --- |
| Haiku 4.5 | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| Sonnet 5.5 | `us.anthropic.claude-sonnet-5-5` |
| Haiku 5.5 | `us.anthropic.claude-haiku-5-5` |

## 再現方法

```bash
# 1. 依存ツールのインストール (tflint, checkov, boto3)
#    tflintはGitHub Releaseからバイナリ取得、checkov/boto3はpipでインストール済みであること

# 2. コード生成(Bedrockの認証情報が必要)
python3 scripts/generate.py

# 3. 評価の実行
python3 scripts/evaluate.py

# 4. レポート生成
python3 scripts/report.py
```

生成結果は [generated/\<model\>/\<task\>/](generated/) に、採点結果は [results/raw_results.json](results/raw_results.json) と [results/report.md](results/report.md) に出力される。

## ディレクトリ構成

```
tasks/      タスク定義(プロンプト)
generated/  各モデルが生成したTerraformコード
scripts/    生成・評価・レポート生成スクリプト
results/    最新(3回目)の評価結果(JSON/Markdown)
runs/       1〜3回目(run1〜run3)の生成コードと評価結果のアーカイブ
```
