# CarrierWave 3.1 + MinIO サンドボックス

CarrierWave 3.1 で `present?` / `exists?` などを呼び出したときに S3 へのアクセス(HEAD リクエスト)が発生するかを、実際の S3 の代わりに [MinIO](https://min.io/) を使ってローカルで検証するサンドボックスです。

関連 issue: [carrierwaveuploader/carrierwave#2776](https://github.com/carrierwaveuploader/carrierwave/issues/2776)
(CarrierWave 3.0.7 → 3.1.x で `CarrierWave::Storage::Fog::File#empty?` が S3 への HEAD リクエストを発行するようになり、`present?` を呼ぶたびに S3 アクセスが走るという報告)

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

### 期待される結果(CarrierWave 3.1.x)

| メソッド | S3 アクセス |
| --- | --- |
| `post[:image].present?`(生カラム) | なし |
| `post.image_url` | なし |
| `post.image.url` | なし |
| `post.image.present?` | **HEAD リクエスト 1 回** |
| `post.image.blank?` | **HEAD リクエスト 1 回** |
| `post.image.file.exists?` | **HEAD リクエスト 1 回** |
| `post.image?` | **HEAD リクエスト 1 回** |
| `post.image.size` | **HEAD リクエスト 1 回** |
| `post.valid?`(バリデーション定義なし) | **HEAD リクエスト 1 回** |
| `validates :image, presence: true`(`valid?` / `save` 時) | **HEAD リクエスト 1 回**(ファイルが S3 上に実在しない場合は **5 回**) |

presence バリデーション付きの `valid?` では `blank?` が 5 回評価されます。ActiveModel の `EachValidator` は `allow_nil` / `allow_blank` のスキップ判定で(オプション未指定でも)毎回 `value.blank?` を呼ぶため、presence に加えて CarrierWave が mount 時に自動追加する integrity / processing / download の各バリデータでも `blank?` が評価され(計 4 回)、さらに `PresenceValidator` 本体の判定で 1 回評価されるためです。

ただし fog は最初の HEAD で取得したファイル情報をメモ化するため、ファイルが S3 上に実在する場合の HTTP リクエストは初回の 1 回だけです。ファイルが実在しない(404)場合はメモ化されず、評価回数ぶんの 5 回の HEAD が発生します。

また、この自動バリデータの `blank?` 評価はバリデーションを何も定義していないモデルでも発生するため、`mount_uploader` しただけのモデルでも `valid?` / `save` のたびに HEAD リクエストが最低 1 回発生します。

※ テストは MinIO の起動が前提です。未起動の場合は `Excon::Error::Socket`(connection refused)で失敗します。

### MinIO 側でリクエストを観測する

MinIO サーバーが実際に受信したリクエストをリアルタイムで確認できます:

```sh
docker compose exec minio sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin && mc admin trace local"
```

この状態で別ターミナルからテストを実行すると、`s3.PutObject` / `s3.HeadObject` / `s3.DeleteObject` などが流れるのが見えます。

## CarrierWave 3.0.7 との挙動比較

issue #2776 の差分を実測したい場合は、Gemfile を以下のように変更して再実行します:

```ruby
gem "carrierwave", "3.0.7"
```

```sh
bundle update carrierwave
bin/rails test test/models/post_test.rb
```

3.0.7 では `image.present?` / `image.blank?` が S3 アクセスを発生させないため、該当テストの HEAD アサートが失敗します(= バージョン間の挙動差を確認できます)。

## 構成のポイント

- `config/initializers/carrierwave.rb` — fog-aws を MinIO に向ける設定。MinIO 固有の必須設定は `endpoint` の明示と `path_style: true` の 2 つ(`path_style` がないと fog は `http://<bucket>.localhost:9000` へ接続しようとして失敗する)。`region` は署名 v4 に必要なだけのダミー値
- `docker-compose.yml` — MinIO 本体と、`mc` によるバケット自動作成(`mc mb -p` は冪等なので `docker compose up` の再実行が安全)
- `app/uploaders/image_uploader.rb` — `storage :fog` の最小構成アップローダー
- `test/models/post_test.rb` — 検証テスト本体
