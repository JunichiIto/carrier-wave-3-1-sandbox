# CarrierWave 3.1 + MinIO サンドボックス

CarrierWave 3.1 で `present?` / `exists?` などを呼び出したときに S3 へのアクセス(HEAD リクエスト)が発生するかを、実際の S3 の代わりに [MinIO](https://min.io/) を使ってローカルで検証するサンドボックスです。

**このブランチ(verify-carrierwave-master-fix)では、issue #2776 の修正コミット [f635d88](https://github.com/carrierwaveuploader/carrierwave/commit/f635d88b9debeda27b25148856ca5e0faa186d17)(master、4.0.0.alpha)を取り込み、修正後の挙動を検証しています。**

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

### 期待される結果(master / #2776 修正後)— 3.1.x との比較

| メソッド | 3.1.x(main ブランチ) | master(このブランチ) |
| --- | --- | --- |
| `post[:image].present?`(生カラム) | なし | なし |
| `post.image_url` / `post.image.url` | なし | なし |
| `post.image.present?` | HEAD 1 回 | **なし** |
| `post.image.blank?` | HEAD 1 回 | **なし** |
| `post.image?` | HEAD 1 回 | **なし** |
| `post.image.exists?`(**新設**) | —(メソッドなし) | **HEAD 1 回** |
| `post.image.file.exists?` | HEAD 1 回 | HEAD 1 回 |
| `post.image.size` | HEAD 1 回 | HEAD 1 回 |
| `post.valid?`(バリデーション定義なし) | HEAD 1 回 | **なし** |
| `validates :image, presence: true`(`valid?` 時) | HEAD 1 回(ファイル不在時は 5 回) | **なし** |

修正の要点:

- **`blank?` / `present?` はストレージに問い合わせなくなり**、「ファイルが割り当てられているか」だけを返す(BREAKING CHANGE)。これにより `present?` / `image?` / presence バリデーション / 自動追加バリデータ経由の HEAD がすべて消える
- ストレージ上の実在確認は**新設の `Uploader#exists?`** に分離された(呼べばリモートでは HEAD 1 回)
- fog の `File#file` のメモ化が `defined?(@file)` 方式になり、**404(不在)もメモ化される**ようになった。3.1.x にあった「不在ファイルはアクセスのたびに HEAD 再発行」(#2698 / #2793)が解消され、`exists?` を 2 回呼んでも HEAD は 1 回で済む
- `size` はストレージが content_length を返さない場合に `NoMethodError` にならず 0 を返す(#2787)

**セマンティクスの変化に注意**: `validates :image, presence: true` は識別子カラムだけで判定するようになったため、DB に識別子が残っていて S3 上のオブジェクトが消えている場合でも **valid** になります(3.1.x ではストレージを見るため invalid でした)。

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
