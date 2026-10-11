# 評価指標の候補

機械的に判定可能であることを優先する。言語・ドメインごとの候補例。

## Terraform / IaC

| 軸 | ツール/方法 | 備考 |
| --- | --- | --- |
| 構文・妥当性 | `terraform validate` | `terraform init -backend=false` の後に実行 |
| フォーマット | `terraform fmt -check -diff` | |
| ベストプラクティス | `tflint` | brewに無ければGitHub Releaseから導入 |
| セキュリティ | `checkov`, `tfsec`, `trivy config` | pip/brewで導入可 |
| 要件カバレッジ | 正規表現で`resource "xxx_yyy"`の存在を確認 | タスクごとに必須リソースのリストを用意 |
| コーディング規約 | snake_case命名、`variable`のtype/description有無、`this`の使い回し禁止、`count`より`for_each`等 | 過去記事・社内規約から機械判定可能な項目のみ抽出 |

## 一般的なスクリプト言語

| 軸 | ツール/方法 |
| --- | --- |
| 構文・実行可能性 | `python -m py_compile`, `node --check`等 |
| Lint | `pylint`, `ruff`, `eslint`等 |
| 型チェック | `mypy`, `tsc --noEmit`等 |
| テスト通過 | 用意したテストケースを実行 |
| セキュリティ | `bandit`, `semgrep`等 |

## 要件カバレッジの実装パターン

タスクごとに「必須要素のリスト」をJSON等で定義し、正規表現マッチで判定する。

```json
{
  "task1_simple": [
    { "name": "S3バケット", "pattern": "resource\\s+\"aws_s3_bucket\"" },
    { "name": "バージョニング有効化", "pattern": "resource\\s+\"aws_s3_bucket_versioning\"" }
  ]
}
```

variableのデフォルト値経由でタグ等を設定している場合、文字列の直接マッチだと見逃す(例: `Project = var.project_name` で`project_name`のデフォルトが目的の値)。要件によっては`variable`の`default`も含めて検索範囲に入れる。

## 誤検知を避けるための注意

複合条件(「AかつB」)を素朴に「Aが文字列として存在」「Bが文字列として存在」の論理積で判定すると、AとBが無関係な場所にあっても真になる。

悪い例(誤検知する):
```python
has_22 = re.search(r"from_port\s*=\s*22", text)
has_open = re.search(r'cidr_blocks\s*=\s*\["0\.0\.0\.0/0"\]', text)
if has_22 and has_open:
    # SSHが0.0.0.0/0に開いていると誤検知する可能性
    # (22番ルールと0.0.0.0/0ルールが別々のingressブロックにあるだけでも真になる)
    ...
```

良い例(ブロック単位でスコープを絞る):
```python
for block in re.finditer(r"ingress\s*\{(?P<body>[^{}]*)\}", text, re.DOTALL):
    body = block.group("body")
    if re.search(r"from_port\s*=\s*22\b", body) and re.search(r'cidr_blocks\s*=\s*\["0\.0\.0\.0/0"\]', body):
        # 同一ブロック内に両方がある場合のみ真
        ...
```

自作の検出ロジックを実装したら、必ず実際の生成コードを2〜3件`grep`で直接確認し、誤検知・検知漏れがないか裏取りする。
