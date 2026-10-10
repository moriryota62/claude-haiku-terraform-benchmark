# タスク3: 複雑 (ALB + ASG + RDS + IAM)

以下の要件を満たすTerraformコード(AWSプロバイダ)を出力してください。
説明文は不要です。コードのみを出力してください。

## 要件

### ネットワーク
- VPCを1つ作成する(CIDRはvariableで指定可能、デフォルト 10.0.0.0/16)
- パブリックサブネットを2つ、プライベートサブネットを2つ、それぞれ異なるAZに作成する
- インターネットゲートウェイとNATゲートウェイ(1つで良い)を作成し、適切なルーティングを行う
  - パブリックサブネット: IGW経由でインターネットに到達可能
  - プライベートサブネット: NATゲートウェイ経由でインターネットに到達可能

### アプリケーション層
- Application Load Balancer (ALB) をパブリックサブネットに作成する
- ALB用セキュリティグループ(インバウンド80番のみ全許可)を作成する
- ALBのターゲットグループを作成する(ヘルスチェック設定を含む)
- Auto Scaling Group (ASG) を作成する
  - プライベートサブネットに配置
  - Launch Templateを使用する
  - インスタンスタイプはvariableで指定可能(デフォルト t3.micro)
  - 最新のAmazon Linux 2023 AMIをdata sourceで取得
  - desired_capacity=2, min=1, max=3
  - ALBのターゲットグループにアタッチする
- ASG用セキュリティグループ(ALBからの80番のみ許可)を作成する

### データベース層
- RDS (MySQLまたはPostgreSQL) をプライベートサブネットに作成する
  - DB subnet groupを作成する
  - マルチAZは不要、単一インスタンスで良い
  - インスタンスクラスはvariableで指定可能(デフォルト db.t3.micro)
  - パスワードは直接記述せず、variableのsensitive属性を使うか、AWS Secrets Managerで管理する
  - RDS用セキュリティグループ(ASGインスタンスからの3306/5432番のみ許可)を作成する

### IAM
- EC2インスタンス用のIAMロールとインスタンスプロファイルを作成する
  - 最低限の権限(例: CloudWatch Logsへの書き込みなど)のポリシーをアタッチする
  - ワイルドカード("*")を使った過度に広い権限は避ける

### 共通
- 全リソースにタグ Project = "haiku-benchmark" を付与する
- AWSプロバイダのregionはvariableで指定可能にする(デフォルト: ap-northeast-1)
- ALBのDNS名、RDSのエンドポイント(機密情報を含まない形)をoutputで出力する

## 出力形式

- providers.tf, variables.tf, main.tf, outputs.tf のように複数ファイルに分けても、main.tfに全てまとめても構わない
- 複数ファイルに分ける場合は、各コードブロックの前に `# ファイル名: xxx.tf` を明記すること
