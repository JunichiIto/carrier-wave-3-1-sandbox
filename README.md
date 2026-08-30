# CarrierWave 3.1 + MinIO サンドボックス

CarrierWave 3.1 で `present?` / `exists?` などを呼び出したときに S3 へのアクセス(HEAD リクエスト)が発生するかを、実際の S3 の代わりに [MinIO](https://min.io/) を使ってローカルで検証するサンドボックスです。

関連 issue: [carrierwaveuploader/carrierwave#2776](https://github.com/carrierwaveuploader/carrierwave/issues/2776)
(CarrierWave 3.0.7 → 3.1.x で `CarrierWave::Storage::Fog::File#empty?` が S3 への HEAD リクエストを発行するようになり、`present?` を呼ぶたびに S3 アクセスが走るという報告)

**このブランチ(verify-carrierwave-3-0-downgrade)では、carrierwave を issue 発生前の 3.0.7 にダウングレードし、3.1 系との挙動差を検証しています。**

## 必要環境

- Ruby 4.0.6
- Docker(MinIO 起動用)

## セットアップ

```sh
bundle install
docker compose up -d   # MinIO 起動 + バケット自動作成
bin/rails db:migrate
```

`docker compose ps` で `minio` が healthy、`createbuckets` が Exited (0) になっていれば準備完了です。
`carrierwave-dev`(development 用)と `carrierwave-test`(test 用)の 2 つのバケットが自動作成されます。

MinIO Web コンソール: http://localhost:9001 (ID/PW: `minioadmin` / `minioadmin`)

## 検証方法

モデルテストが検証の本体です。Excon(fog-aws が使う HTTP クライアント)のインストルメンテーションで `excon.request` イベントを購読し、各メソッド呼び出しが MinIO への HTTP リクエストを発生させるかをアサートしています。

MinIO の起動(ヘルシー待ち + バケット作成)とテスト実行は rake タスクにまとめてあります:

```sh
bin/rails verify
```

MinIO が起動済みであれば、テストだけを直接実行しても構いません:

```sh
bin/rails test test/models/post_test.rb
```

### 期待される結果(3.0.7)— 3.1.x との比較

| メソッド | 3.1.x(main ブランチ) | 3.0.7(このブランチ) |
| --- | --- | --- |
| `post[:image].present?`(生カラム) | なし | なし |
| `post.image_url` / `post.image.url` | なし | なし |
| `post.image.present?` | HEAD 1 回 | **なし** |
| `post.image.blank?` | HEAD 1 回 | **なし** |
| `post.image?` | HEAD 1 回 | **なし** |
| `post.image.file.exists?` | HEAD 1 回 | HEAD 1 回 |
| `post.image.size` | HEAD 1 回 | HEAD 1 回 |
| `post.valid?`(バリデーション定義なし) | HEAD 1 回 | **なし** |
| `validates :image, presence: true`(`valid?` 時) | HEAD 1 回(ファイル不在時は 5 回) | **なし** |

3.0 系の `Storage::Fog::File` には `empty?` がないため、`blank?` / `present?` はストレージに問い合わせません。3.1.x で HEAD が発生していた箇所(自動追加バリデータ経由の `valid?` を含む)は、3.0.7 ではすべて S3 アクセスなしになります。

また、presence バリデーションは識別子ベースの判定になるため、**S3 上のオブジェクトが消えていても valid** です(3.1.x では invalid + HEAD 5 回)。この点は #2776 修正後の master(4.0.0.alpha)と同じセマンティクスです。

※ 3.0.7 を Rails 8.1 で動かすと、テスト実行時に `String#mb_chars is deprecated and will be removed in Rails 8.2` の警告が多数出ます(carrierwave 3.0 系の `SanitizedFile` が使用しているため)。ダウングレードでの回避は Rails 8.2 以降では成立しなくなる点に注意してください。

※ テストは MinIO の起動が前提です。未起動の場合は `Excon::Error::Socket`(connection refused)で失敗します。

### MinIO 側でリクエストを観測する

MinIO サーバーが実際に受信したリクエストをリアルタイムで確認できます:

```sh
docker compose exec minio sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin && mc admin trace local"
```

この状態で別ターミナルからテストを実行すると、`s3.PutObject` / `s3.HeadObject` / `s3.DeleteObject` などが流れるのが見えます。

## 構成のポイント

- `config/initializers/carrierwave.rb` — fog-aws を MinIO に向ける設定。MinIO 固有の必須設定は `endpoint` の明示と `path_style: true` の 2 つ(`path_style` がないと fog は `http://<bucket>.localhost:9000` へ接続しようとして失敗する)。`region` は署名 v4 に必要なだけのダミー値
- `docker-compose.yml` — MinIO 本体と、`mc` によるバケット自動作成(`mc mb -p` は冪等なので `docker compose up` の再実行が安全)
- `app/uploaders/image_uploader.rb` — `storage :fog` の最小構成アップローダー
- `test/models/post_test.rb` — 検証テスト本体
