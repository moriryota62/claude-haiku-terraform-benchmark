# claude-haiku-terraform-benchmark

Claude Haiku 5.5 がリリースされた。今までTerraformのコーディングは Sonnet などのモデルを使用してきたが、Terraformのコーディングはそこまで難しくない。Haiku 5.5 なら十分品質の高いコードが生成出来るのではないかと考えている。

この仮説を検証するため、同一の要件を Claude Haiku 4.5 / Claude Sonnet 5.5 / Claude Haiku 5.5 の3モデルに与えてTerraformコードを生成させ、客観的な指標でコード品質を比較する。

## 結果

**[results/report.md](results/report.md)** に比較レポートをまとめている。要点:

- 全モデル・全タスクで `terraform validate` は通過し、要件カバレッジ(必須リソースの実装)もほぼ100%だった
- Haiku 4.5 は複雑なタスクで `terraform fmt` の崩れやセキュリティ上の懸念(SSH全開放)が見られた
- Haiku 5.5 は Sonnet 5.5 に近いスコアを達成しており、タスク1(シンプル)・タスク2(中程度)ではほぼ同等だった
- タスク3(複雑)では Sonnet 5.5 がcheckovの通過率で優位だった

## 検証方法

1. 3段階の複雑さを持つAWS Terraformタスクを用意する([tasks/](tasks/))
   - タスク1: S3バケット単体(シンプル)
   - タスク2: VPC + EC2 + セキュリティグループ(中程度)
   - タスク3: ALB + ASG + RDS + IAM(複雑)
2. Amazon Bedrock経由で3モデルに同一プロンプトを与え、コードを生成する([scripts/generate.py](scripts/generate.py))
3. 生成されたコードを5つの客観的指標で採点する([scripts/evaluate.py](scripts/evaluate.py))
   - `terraform fmt -check`: フォーマット規約準拠
   - `terraform validate`: 構文・設定の妥当性
   - [tflint](https://github.com/terraform-linters/tflint): Terraformベストプラクティス違反
   - [checkov](https://www.checkov.io/): セキュリティ・コンプライアンスのポリシー違反
   - 要件カバレッジ: タスクで要求した必須リソースが実装されているか(正規表現マッチ)
   - セキュリティアンチパターン: SSH全開放・認証情報のハードコードなどの簡易検出
4. 各指標を重み付けしてスコア化し、レポートを生成する([scripts/report.py](scripts/report.py))

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
results/    評価結果(JSON/Markdown)
```
