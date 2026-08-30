# CarrierWave 3.1 の `present?` は S3 にアクセスする 〜3.0 / 3.1 / 4.0 の仕様の違いと注意点まとめ〜

## これは何

CarrierWave を 3.0 系から 3.1 系にアップグレードすると、`post.image.present?` や `post.image?`、さらには**モデルの `valid?` / `save` を呼ぶだけ**で S3 への HEAD リクエストが発生するようになります。レコードを一覧表示するページなら、レコード件数ぶんの HEAD リクエストが S3 に飛びます。

この挙動は 3.0 系 / 3.1 系 / 次期メジャーバージョン(master)で三者三様です。先に結論をまとめると次のとおりです。

| | 3.0 系 | 3.1 系 | master(4.0.0.alpha) |
| --- | --- | --- | --- |
| `present?` / `blank?` の意味 | 割り当ての有無 | **ストレージ実在確認**(HEAD 発生) | 割り当ての有無 |
| ストレージ実在確認の手段 | `file.exists?` | `file.exists?` | **`exists?`(公式 API)** |
| `valid?` / `save` の S3 アクセス | なし | あり | なし |
| 404 のメモ化 | されない(影響は小さい) | されない(再発行される) | される |

この記事では、前半で**各バージョンの仕様の違いと注意点**をまとめ、後半でその**根拠となる検証方法**(MinIO を使ったサンプルアプリでの実測)を紹介します。

📦 サンプルアプリ: https://github.com/JunichiIto/carrier-wave-3-1-sandbox

## 背景: なぜバージョンごとに挙動が違うのか

発端は issue [#2776](https://github.com/carrierwaveuploader/carrierwave/issues/2776) です。「CarrierWave を 3.0.7 から 3.1.1 に上げたら、S3 への HEAD リクエストが激増してパフォーマンスが悪化した」という報告でした。

原因は 3.1.0 で入った `CarrierWave::Storage::Fog::File#empty?` です。もともとローカルストレージ(`SanitizedFile#empty?`)はファイルシステムを見て空かどうかを判定していたのに対し、fog ストレージには `empty?` がなく、両者で `present?` の意味がズレていました。3.1.0 はこれを「ストレージに問い合わせる」方向で揃えた([#1926](https://github.com/carrierwaveuploader/carrierwave/issues/1926))のですが、その結果、リモートストレージでは `blank?` / `present?` のたびに HEAD リクエストが飛ぶようになりました。ActiveSupport の `present?` は `!blank?` なので、Rails らしい書き方をしているコードはほぼすべてこの経路を通ります。

そして 2026 年 8 月、master ブランチに修正コミット [f635d88](https://github.com/carrierwaveuploader/carrierwave/commit/f635d88b9debeda27b25148856ca5e0faa186d17) が入り、`present?`(割り当ての有無)と `exists?`(ストレージ実在確認)が分離されました。

なお、執筆時点の master は `lib/carrierwave/version.rb` で `VERSION = "4.0.0.alpha"` を宣言しており、CHANGELOG にも複数の BREAKING CHANGE が並んでいます。次期メジャーバージョンに入る可能性が高いため、この記事では master のことを **4.0.0.alpha** と呼びます(正式なリリースバージョンが確定しているわけではない点にご注意ください)。

## バージョン別の仕様と注意点

### 3.0 系: 存在チェックはストレージに問い合わせない

3.0 系の `Storage::Fog::File` には `empty?` がなく、`blank?` / `present?` はストレージに問い合わせません。`present?` / `image?` / `valid?` / presence バリデーションのいずれも S3 アクセスなしで動きます。

presence バリデーションは識別子カラム(DB)ベースの判定なので、**S3 上のオブジェクトが消えていても valid** です。これは後述する 4.0.0.alpha と同じセマンティクスで、3 バージョンの中では「ストレージを見る」3.1 系だけが特殊だった、ということになります。

**注意点**: 「3.1 で問題が出たから 3.0 に留まる(戻す)」という回避は取れません。理由は 2 つあります。

- **セキュリティ**: 3.0 系には既知の脆弱性 [CVE-2026-44587](https://www.cve.org/CVERecord?id=CVE-2026-44587)(`denylisted_content_type` のバイパス、3.1.3 で修正)があり、bundler-audit にも検出されます
- **Rails との互換性**: 3.0.7 を Rails 8.1 で動かすと `String#mb_chars is deprecated and will be removed in Rails 8.2` の警告が大量に出ます(3.0 系の `SanitizedFile` が使用しているため)。Rails 8.2 以降では動かなくなる見込みです

### 3.1 系: 「ファイルがあるか?」系がすべて S3 を叩く

3.1 系で S3 アクセスが発生するメソッドの実測結果です(検証方法は後半で説明します)。

| メソッド | S3 アクセス |
| --- | --- |
| `post[:image].present?`(生カラム) | なし |
| `post.image_url` / `post.image.url` | なし |
| `post.image.present?` | **HEAD 1 回** |
| `post.image.blank?` | **HEAD 1 回** |
| `post.image?` | **HEAD 1 回** |
| `post.image.size` | **HEAD 1 回** |
| `post.image.file.exists?` | **HEAD 1 回** |
| `post.valid?`(バリデーション定義なし!) | **HEAD 1 回** |
| `validates :image, presence: true` の `valid?` | **HEAD 1 回**(ファイル不在時は **5 回**) |

URL の生成(`image_url` / `image.url`)は文字列操作だけなのでセーフ、識別子カラムを直接見る `post[:image].present?` もセーフです。それ以外の「ファイルがあるか?」系はすべて S3 に問い合わせに行きます。

3.1 系を使ううえでの注意点は 3 つあります。

**注意点 1: バリデーションを定義していなくても `valid?` / `save` で S3 アクセスが発生する**

CarrierWave は mount 時に integrity / processing / download の 3 つのバリデータを自動で追加します。ActiveModel のバリデータには `allow_nil` / `allow_blank` のスキップ判定として `value.blank?` を呼ぶ経路があり(詳細は後半で解説)、この `blank?` が S3 を叩きます。つまり **`mount_uploader` しただけのモデルは、保存のたびに S3 へ HEAD リクエストを送ります**。

**注意点 2: HEAD の回数は「ファイルが S3 上に実在するか」で変わる**

fog は最初の HEAD で取得したファイル情報をメモ化するため、ファイルが実在する場合の HTTP リクエストは通常 1 回で済みます。ところが **404(不在)はメモ化されません**。DB に識別子が残っているのに S3 上のオブジェクトが消えているレコードでは、`valid?` 1 回で HEAD が 5 回飛びます([#2698](https://github.com/carrierwaveuploader/carrierwave/pull/2698) / [#2793](https://github.com/carrierwaveuploader/carrierwave/pull/2793) で報告されていた問題)。「基本 1 回だから大丈夫」と思っていると、データ不整合のあるレコードだけ極端にリクエストが増える、という嫌な性質です。

**注意点 3: 一覧ページは N+1 的に HEAD が増える**

レコードごとに `if post.image.present?` のような分岐をしていると、レコード件数ぶんの HEAD リクエストが発生します(レイテンシ増 + S3 のリクエスト課金)。存在チェックが「画像が添付されているか」の意味であれば、識別子カラムを見る方法(`post[:image].present?` や、mount 時に定義される `post.image_identifier`)に置き換えれば S3 アクセスなしで済みます。

### 4.0.0.alpha(master): `present?` と `exists?` の分離

修正コミット f635d88 の考え方はコミットメッセージに明快に書かれています。3.1.0 は「ファイルが割り当てられているか」と「ファイルがストレージに実在するか」という**別の質問を混同して**、両方を高コストな後者に揃えてしまった。そこでこの 2 つを分離する:

- **`blank?` / `present?`** → 「ファイルが割り当てられているか」だけを返す。識別子で判定でき、ストレージには問い合わせない(BREAKING CHANGE)
- **`exists?`(新設)** → 「ストレージに実在するか」を返す。呼べばリモートでは HEAD 1 回

3.1.x との実測比較は次のとおりです。

| メソッド | 3.1.x | master(4.0.0.alpha) |
| --- | --- | --- |
| `post.image.present?` / `blank?` / `image?` | HEAD 1 回 | **なし** |
| `post.image.exists?`(**新設**) | —(メソッドなし) | HEAD 1 回 |
| `post.image.file.exists?` / `image.size` | HEAD 1 回 | HEAD 1 回 |
| `post.valid?`(バリデーション定義なし) | HEAD 1 回 | **なし** |
| `validates :image, presence: true` の `valid?` | HEAD 1 回(不在時 5 回) | **なし** |
| ファイル不在時に `exists?` を 2 回呼ぶ | (`file.exists?` 相当で 2 回) | **HEAD 1 回**(404 もメモ化) |

3.1 系の注意点 2(404 の再発行)も修正されており、不在ファイルもメモ化されるようになっています。

S3 アクセスは消えますが、**`present?` の意味が変わる** BREAKING CHANGE なので、アップグレード時は次の点に注意が必要です。

- `present?` は「ファイルが割り当てられているか」であり、**ストレージ上の実在確認ではなくなります**。実在確認が必要な箇所は新設の `exists?` に置き換える必要があります
- `validates :image, presence: true` は識別子カラムだけで判定するため、**S3 上のオブジェクトが消えていても valid になります**(3.1 系では invalid でした)。「ストレージ欠損の検出」をバリデーションに期待していたコードは動かなくなります
- version(サムネイルなど)の `present?` も「親が present なら present」を返すようになるため、「条件付き version が実際に生成されたか」の判定は `exists?` で明示的に行う必要があります

## 現時点ではどうすればいいか(4.0 リリースまで)

ここまでをまとめると「3.0 は使い続けられない(CVE + Rails 8.2 非互換)、でも修正版の 4.0 はまだリリースされていない」という状況です。現時点の現実的な方針は次のとおりです。

**大前提として 3.1.3 を使います**(CVE-2026-44587 の修正版)。そのうえで、S3 アクセス問題が自分のアプリで実害になっているか(APM のレイテンシ、S3 のリクエスト数・課金)をまず測ります。一覧ページで `present?` を呼んでいない、`save` 頻度が低い、といったアプリなら 3.1.3 のまま 4.0 を待つだけで十分です。

実害がある場合の選択肢は 3 つあります。

**選択肢 1: 存在チェックを識別子カラムベースに書き換える**

`post.image.present?` を `post[:image].present?` や `post.image_identifier.present?` に置き換えれば、その箇所の S3 アクセスは消えます。gem の内部に触らないので最も安全ですが、呼び出し側の書き換えが必要で、CarrierWave が mount 時に自動追加するバリデータ由来の `valid?` / `save` 時の HEAD は残ります。

**選択肢 2: 修正コミットをモンキーパッチとして移植する(検証済み)**

修正コミット f635d88 はパッチ対象が 2 クラス 4 メソッドと小さく自己完結しているため、initializer 1 ファイルで 3.1.3 に移植できます。[verify-monkey-patch-2776 ブランチ](https://github.com/JunichiIto/carrier-wave-3-1-sandbox/tree/verify-monkey-patch-2776)で、**3.1.3 + このパッチが master 取り込み時とまったく同じ挙動になる**ことをテストで確認済みです。

```ruby
# config/initializers/carrierwave_patch_2776.rb
require "carrierwave/storage/fog"

unless CarrierWave::VERSION == "3.1.3"
  raise "carrierwave が 3.1.3 以外(#{CarrierWave::VERSION})になっています。" \
        "このモンキーパッチがまだ必要か確認し、不要なら " \
        "config/initializers/carrierwave_patch_2776.rb を削除してください。"
end

module CarrierWavePatch2776
  module UploaderProxyPatch
    # blank? / present? は「ファイルが割り当てられているか」だけを返し、
    # ストレージには問い合わせない
    def blank?
      return true unless file
      return file.empty? if cached?

      false
    end

    # ストレージ上の実在確認(リモートストレージでは HEAD リクエストが発生する)
    def exists?
      !!file&.exists?
    end
  end

  module FogFilePatch
    def read
      file_body = file&.body

      return if file_body.nil?
      return file_body unless file_body.is_a?(::File)
      return read_source_file if ::File.exist?(file_body.path)

      remove_instance_variable(:@file)
      file.body
    end

    def size
      file&.content_length || 0
    end

    private

    # 404(不在)もメモ化し、アクセスのたびに HEAD が再発行されるのを防ぐ
    def file
      return @file if defined?(@file)

      @file = directory.files.head(path)
    end
  end
end

CarrierWave::Uploader::Base.prepend CarrierWavePatch2776::UploaderProxyPatch
CarrierWave::Storage::Fog::File.prepend CarrierWavePatch2776::FogFilePatch
```

ポイント:

- `Module#prepend` 方式なのでロード順に対して頑健です(クラスの再オープンだと、パッチより後に gem 本体が読み込まれた場合に上書きされるリスクがあります)
- **バージョンガードは必須**です。3.1.4 や 4.0 に上げたときにパッチが黙って残留・競合する事故を防ぎます
- 4.0 リリース時は initializer を削除して `bundle update carrierwave` するだけで移行できます
- `present?` のセマンティクス変化(前章の注意点)を今すぐ引き受けることになる点は理解しておく必要があります
- `read` 内の `remove_instance_variable` も本家に合わせて移植していますが、fog-aws では `body` が String で返るためこの分岐には到達しないことを実測で確認しています(body が `::File` を返しうる他の fog プロバイダ向けの防御的な移植)

**選択肢 3: master を SHA 固定で使う**

`gem "carrierwave", github: "carrierwaveuploader/carrierwave", ref: "f635d88..."` のように SHA 固定すれば修正は今すぐ手に入りますが、master には URL デコードの変更など**他の BREAKING CHANGE も含まれ**、リリース前に挙動が変わる可能性もあります。テストが厚く、差分を追える体制のあるチーム向けです。

どの選択肢も `present?` まわりの挙動は「識別子ベースの判定」に変わるため、4.0 リリース後の移行はスムーズです。個人的なおすすめは、影響箇所が少ないなら選択肢 1、`present?` の呼び出し箇所が多くて書き換えコストが高いなら選択肢 2 です。

## 根拠: サンプルアプリで実測する

ここからは、上記の仕様差をどうやって確認したかを紹介します。実際の S3 の代わりに [MinIO](https://min.io/) を Docker で立て、HTTP クライアント(Excon)のリクエストを購読して「このメソッドを呼ぶと S3 に何回リクエストが飛ぶか」をテストコードでアサートする、という構成です。手元で全部再現できます。

### 検証環境

- Ruby 4.0.6 / Rails 8.1.3(API モード)
- carrierwave 3.1.3 / fog-aws 3.33.3(ブランチによって 3.0.7 / master に差し替え)
- MinIO(latest)を docker-compose で起動

### 検証方法: Excon のリクエストを購読する

fog-aws は HTTP クライアントに Excon を使っています。Excon にはインストルメンテーション機構があり、`ActiveSupport::Notifications` をインストルメンタに指定すると、リクエストのたびに `excon.request` イベントが飛んできます。

これをテストの setup で購読しておけば、「あるメソッド呼び出しが S3 に何回・どんなリクエストを送ったか」をそのままアサートできます。

```ruby
class PostTest < ActiveSupport::TestCase
  # fog の接続は遅延生成なので、最初の接続が作られる前にここで設定すれば全リクエストに効く
  Excon.defaults[:instrumentor] = ActiveSupport::Notifications

  setup do
    @requests = []
    @subscriber = ActiveSupport::Notifications.subscribe("excon.request") do |_name, _start, _finish, _id, payload|
      @requests << "#{payload[:method].to_s.upcase} #{payload[:path]}"
    end

    created = Post.create!(title: "sample", image: File.open(file_fixture("sample.png")))
    @post = Post.find(created.id) # アップロード時の状態をキャッシュしていないフレッシュなインスタンスで検証する
    @requests.clear               # 作成時の PUT リクエストなどを捨てて計測を初期化
  end

  test "image.present? は S3 への HEAD リクエストを発生させる (issue #2776)" do
    @post.image.present?
    assert_head @requests
  end

  private

  def assert_head(requests, count: 1)
    head_count = requests.count { |r| r.start_with?("HEAD ") }
    assert_equal count, head_count, "expected #{count} HEAD request(s), got: #{requests.inspect}"
  end
end
```

モデルは CarrierWave の最小構成です。

```ruby
class Post < ApplicationRecord
  mount_uploader :image, ImageUploader
end
```

MinIO 側の設定は Gemfile 差し替えなしで S3 互換の挙動を再現するためのもので、ポイントは `endpoint` の明示と `path_style: true` の 2 つだけです(詳細はリポジトリの README を参照してください)。

### ブランチ構成: バージョンごとの挙動をテストで記録する

サンプルアプリでは、バージョンごとの挙動をブランチで分けて記録しています。

| ブランチ | carrierwave | 内容 |
| --- | --- | --- |
| [main](https://github.com/JunichiIto/carrier-wave-3-1-sandbox/tree/main) | 3.1.3 | 3.1 系の挙動を記録したテスト(前半の表の根拠) |
| [verify-carrierwave-3-0-downgrade](https://github.com/JunichiIto/carrier-wave-3-1-sandbox/tree/verify-carrierwave-3-0-downgrade) | 3.0.7 | 3.0 系にダウングレードして挙動差を検証 |
| [verify-carrierwave-master-fix](https://github.com/JunichiIto/carrier-wave-3-1-sandbox/tree/verify-carrierwave-master-fix) | master(f635d88) | 修正コミット取り込み後の挙動を検証 |
| [verify-monkey-patch-2776](https://github.com/JunichiIto/carrier-wave-3-1-sandbox/tree/verify-monkey-patch-2776) | 3.1.3 + モンキーパッチ | 修正コミットをモンキーパッチとして移植し、master と同じ挙動になることを検証 |

検証の手順はどちらの差し替えブランチも同じで、「main のテスト(3.1.3 の挙動を記録)を差し替え後にそのまま実行 → 失敗を観察 → 新しい挙動に期待値を更新」という流れです。

面白いのは、**3.0.7 に下げても master に上げても、失敗するテストがまったく同じ 6 件**(すべて「HEAD を期待したが 0 回だった」)になることです。`present?` / `blank?` / `image?` / `valid?` / presence バリデーションの S3 アクセスは 3.1 系にしか存在しない、ということがテストの失敗パターンからも分かります。

### 深掘り 1: なぜ `valid?` だけで S3 アクセスが発生するのか

3.1 系の注意点 1 の内部実装です。CarrierWave が自動追加する 3 つのバリデータは `ActiveModel::EachValidator` のサブクラスで、`EachValidator#validate` には次のようなスキップ判定があります。

```ruby
# activemodel/lib/active_model/validations/validator.rb(抜粋)
def validate(record)
  attributes.each do |attribute|
    value = record.read_attribute_for_validation(attribute)
    next if (value.nil? && options[:allow_nil]) || (value.blank? && options[:allow_blank])
    # ...
  end
end
```

`allow_blank` オプションを指定していなくても、Ruby の `&&` は左辺を先に評価するので `value.blank?` は**必ず呼ばれます**。`value` はアップローダーなので、`blank?` → `file.empty?` → HEAD リクエスト、という経路です。

presence バリデーション付きの `valid?` では、この経路で `blank?` が合計 5 回評価されます(自動追加の 3 バリデータ + presence のスキップ判定で 4 回、`PresenceValidator` 本体で 1 回)。

### 深掘り 2: なぜ HEAD の回数がファイルの実在で変わるのか

3.1 系の注意点 2 の内部実装です。fog のファイル取得は次のようにメモ化されています。

```ruby
# carrierwave 3.1.3 lib/carrierwave/storage/fog.rb
def file
  @file ||= directory.files.head(path)
end
```

`||=` でのメモ化なので、ファイルが実在すれば 2 回目以降はメモ化が効いて HTTP は初回の 1 回だけ。しかし HEAD が 404 を返すと `nil` が「キャッシュされず」、アクセスのたびに HEAD が再発行されます。`blank?` の評価 5 回がそのまま HEAD 5 回になるのはこのためです。

master ではここも修正されています。

```ruby
# master lib/carrierwave/storage/fog.rb
def file
  return @file if defined?(@file)

  @file = directory.files.head(path)
end
```

`defined?(@file)` 方式に変わったことで、404(不在)もメモ化されるようになりました。

### 補足: `image.empty?` はどのバージョンでも呼べない

`@post.image.empty?` という呼び出しはどのバージョンでも `NoMethodError` です。`empty?` が定義されているのはファイルオブジェクト側(`SanitizedFile` / `Storage::Fog::File`)だけで、アップローダーには生えていません。issue で問題になったのは `present?` / `blank?` が**内部で** `file.empty?` を呼ぶ経路です。

## まとめ

- CarrierWave 3.1 系では「ファイルがあるか?」系のメソッドとバリデーション(自動追加分を含む)が S3 を叩く。3.0 系からのアップグレード時はパフォーマンスとコストに注意
- 3.0 系へのダウングレードは CVE-2026-44587 と Rails 8.2 非互換(`String#mb_chars` 削除)のため選択肢にならない
- master(4.0.0.alpha)では `present?`(割り当て)と `exists?`(実在)が分離されて解決。ただし `present?` と presence バリデーションのセマンティクスが変わるので、実在確認に依存していたコードは `exists?` への置き換えが必要
- 4.0 リリースまでの現実的な対処は「3.1.3 + 識別子ベースの書き換え」または「3.1.3 + 修正コミットのモンキーパッチ」。どちらも 4.0 のセマンティクスの先取りになるため、リリース後の移行もスムーズ

検証に使ったサンプルアプリはこちらです。`docker compose up -d` と `bin/rails verify` だけで全部再現できるので、ぜひ手元で試してみてください。

https://github.com/JunichiIto/carrier-wave-3-1-sandbox

## 参考リンク

- [issue #2776: Excessive HEAD requests to S3 after upgrading to 3.1.1](https://github.com/carrierwaveuploader/carrierwave/issues/2776)
- [修正コミット f635d88: Stop asking the storage whether the file is there in #blank?](https://github.com/carrierwaveuploader/carrierwave/commit/f635d88b9debeda27b25148856ca5e0faa186d17)
- [issue #1926: fog と file ストレージで present? の意味を揃えた経緯](https://github.com/carrierwaveuploader/carrierwave/issues/1926)
- [#2698](https://github.com/carrierwaveuploader/carrierwave/pull/2698) / [#2793](https://github.com/carrierwaveuploader/carrierwave/pull/2793): 404 が再発行される問題
- [CVE-2026-44587](https://www.cve.org/CVERecord?id=CVE-2026-44587): 3.0 系に残る denylisted_content_type バイパス脆弱性(3.1.3 で修正)
