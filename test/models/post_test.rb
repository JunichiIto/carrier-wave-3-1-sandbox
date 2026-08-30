require "test_helper"

# present? / exists? などの呼び出しで S3(MinIO)への HTTP リクエストが
# 発生するかを Excon のインストルメンテーションで観測する。
# 関連 issue: https://github.com/carrierwaveuploader/carrierwave/issues/2776
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

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    # トランザクションロールバックでは MinIO 上のオブジェクトは消えないため明示削除
    @post.image.remove!
  end

  test "生カラムの present? では S3 アクセスは発生しない" do
    @post[:image].present?
    assert_empty @requests
  end

  test "image_url では S3 アクセスは発生しない" do
    @post.image_url
    assert_empty @requests
  end

  test "image.url では S3 アクセスは発生しない" do
    @post.image.url
    assert_empty @requests
  end

  test "image.present? は S3 への HEAD リクエストを発生させる (issue #2776)" do
    @post.image.present?
    assert_head @requests
  end

  test "image.blank? は S3 への HEAD リクエストを発生させる" do
    @post.image.blank?
    assert_head @requests
  end

  test "image.file.exists? は S3 への HEAD リクエストを発生させる" do
    @post.image.file.exists?
    assert_head @requests
  end

  test "image? は S3 への HEAD リクエストを発生させる" do
    @post.image?
    assert_head @requests
  end

  test "image.size は S3 への HEAD リクエストを発生させる" do
    @post.image.size
    assert_head @requests
  end

  test "バリデーションを定義していなくても valid? は S3 への HEAD リクエストを発生させる" do
    @post.valid?

    # CarrierWave が mount 時に自動追加する integrity / processing / download バリデータの
    # スキップ判定(EachValidator#validate の value.blank?)により HEAD が発生する
    assert_head @requests
  end

  test "validates :image, presence: true のバリデーションは S3 への HEAD リクエストを発生させる" do
    post = PostWithImageValidation.create!(title: "sample", image: File.open(file_fixture("sample.png")))
    post = PostWithImageValidation.find(post.id)
    @requests.clear

    post.valid?

    # valid? 中に blank? は 5 回評価される(EachValidator の allow_nil / allow_blank
    # スキップ判定が presence + CarrierWave 自動追加の integrity / processing / download
    # の各バリデータで計 4 回、PresenceValidator 本体の判定で 1 回)。
    # ただし fog は最初の HEAD で取得したファイル情報を @file にメモ化するため、
    # ファイルが S3 上に実在する場合の HTTP リクエストは初回の 1 回だけになる
    assert_head @requests
  ensure
    post&.image&.remove!
  end

  test "ファイルが実在しない場合、presence バリデーションは blank? の評価回数ぶん HEAD リクエストを発生させる" do
    post = PostWithImageValidation.create!(title: "sample", image: File.open(file_fixture("sample.png")))
    post.image.file.delete # DB の識別子は残したまま、S3 上のオブジェクトだけを削除する
    post = PostWithImageValidation.find(post.id)
    @requests.clear

    post.valid?

    # 404 の場合 fog はファイル情報をメモ化しないため、blank? の評価 5 回がそのまま HEAD 5 回になる
    assert_head @requests, count: 5
  end

  test "画像が添付されていない場合は present? や valid? を呼んでも S3 アクセスは発生しない" do
    post = Post.create!(title: "no image")
    post = Post.find(post.id)
    @requests.clear

    # 識別子カラムが空だと、blank? はストレージの File オブジェクトを
    # 組み立てる前に true を返すため、S3 には一切問い合わせない
    assert_not post.image.present?
    assert post.image.blank?
    assert_nil post.image.presence
    assert_not post.image?
    assert post.valid?
    assert post.save
    assert_empty @requests
  end

  test "画像が添付されていない場合、presence バリデーションも S3 アクセスなしで invalid になる" do
    post = PostWithImageValidation.new(title: "no image")

    assert_not post.valid?
    assert post.errors.of_kind?(:image, :blank)
    assert_empty @requests
  end

  # presence バリデーション検証用のモデル(Post 本体は最小構成のまま保つ)
  class PostWithImageValidation < Post
    validates :image, presence: true
  end

  private

  def assert_head(requests, count: 1)
    head_count = requests.count { |r| r.start_with?("HEAD ") }
    assert_equal count, head_count, "expected #{count} HEAD request(s), got: #{requests.inspect}"
  end
end
