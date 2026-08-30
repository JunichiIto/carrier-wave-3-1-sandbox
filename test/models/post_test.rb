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

  test "image.present? は S3 アクセスを発生させない(3.0 系)" do
    # 3.0 系の Storage::Fog::File には empty? がないため、blank? は
    # ストレージに問い合わせず false を返す(3.1 系で HEAD が発生するようになった)
    assert @post.image.present?
    assert_empty @requests
  end

  test "image.blank? は S3 アクセスを発生させない" do
    assert_not @post.image.blank?
    assert_empty @requests
  end

  test "image.file.exists? は S3 への HEAD リクエストを発生させる(3.1 系と同じ)" do
    @post.image.file.exists?
    assert_head @requests
  end

  test "image? は S3 アクセスを発生させない" do
    assert @post.image?
    assert_empty @requests
  end

  test "image.size は S3 への HEAD リクエストを発生させる(3.1 系と同じ)" do
    @post.image.size
    assert_head @requests
  end

  test "バリデーションを定義していないモデルの valid? は S3 アクセスを発生させない" do
    # CarrierWave 自動追加の integrity / processing / download バリデータの
    # スキップ判定(EachValidator#validate の value.blank?)は 3.0 系でも通るが、
    # blank? がストレージに問い合わせないため HEAD は発生しない
    @post.valid?
    assert_empty @requests
  end

  test "validates :image, presence: true のバリデーションは S3 アクセスを発生させない" do
    post = PostWithImageValidation.create!(title: "sample", image: File.open(file_fixture("sample.png")))
    post = PostWithImageValidation.find(post.id)
    @requests.clear

    assert post.valid?
    assert_empty @requests
  ensure
    post&.image&.remove!
  end

  test "ファイルが実在しなくても presence バリデーションは valid になる" do
    post = PostWithImageValidation.create!(title: "sample", image: File.open(file_fixture("sample.png")))
    post.image.file.delete # DB の識別子は残したまま、S3 上のオブジェクトだけを削除する
    post = PostWithImageValidation.find(post.id)
    @requests.clear

    # 3.0 系の blank? は識別子ベースの判定なので、S3 上のオブジェクトが消えていても
    # valid になり、S3 アクセスも発生しない(3.1 系では invalid + HEAD 5 回)
    assert post.valid?
    assert_empty @requests
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
