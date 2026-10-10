# タスク1: シンプル (S3バケット)

以下の要件を満たすTerraformコード(AWSプロバイダ)を1つのコードブロックで出力してください。
説明文は不要です。コードのみを出力してください。

## 要件

- プライベートなS3バケットを1つ作成する
- バージョニングを有効化する
- サーバーサイド暗号化(SSE-S3またはKMS)を有効化する
- パブリックアクセスを全てブロックする(aws_s3_bucket_public_access_block)
- バケット名はvariableで指定可能にする(デフォルト値任意)
- 作成したバケット名とARNをoutputで出力する
- AWSプロバイダのregionはvariableで指定可能にする(デフォルト: ap-northeast-1)

## 出力形式

- providers.tf, variables.tf, main.tf, outputs.tf のように複数ファイルに分けても、main.tfに全てまとめても構わない
- 複数ファイルに分ける場合は、各コードブロックの前に `# ファイル名: xxx.tf` を明記すること
