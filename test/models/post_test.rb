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

  test "image.present? は S3 アクセスを発生させなくなった (#2776 修正のモンキーパッチ)" do
    # モンキーパッチ適用後は blank? / present? は「ファイルが割り当てられているか」
    # だけを返すようになり、ストレージには問い合わせない
    assert @post.image.present?
    assert_empty @requests
  end

  test "image.blank? は S3 アクセスを発生させなくなった" do
    assert_not @post.image.blank?
    assert_empty @requests
  end

  test "image.exists? はストレージの実在確認として新設され、S3 への HEAD リクエストを発生させる" do
    # 実在確認は present? から分離され、新設の Uploader#exists? が担う
    assert @post.image.exists?
    assert_head @requests
  end

  test "ファイルが実在しない場合の image.exists? は false を返し、2 回呼んでも HEAD は 1 回で済む" do
    @post.image.file.delete # DB の識別子は残したまま、S3 上のオブジェクトだけを削除する
    post = Post.find(@post.id)
    @requests.clear

    2.times { assert_not post.image.exists? }

    # 404(不在)も defined?(@file) 方式でメモ化されるようになったため(#2698 / #2793)、
    # 3.1.x のようにアクセスのたびに HEAD が再発行されることはない
    assert_head @requests
  end

  test "image.file.exists? は S3 への HEAD リクエストを発生させる(変化なし)" do
    @post.image.file.exists?
    assert_head @requests
  end

  test "image.read でファイル本文を取得できる(file のメモ化方式変更後も壊れていない)" do
    # パッチは file のメモ化を defined? 方式に変えているため、
    # read が正しく動作することの回帰ガードとして本文の取得を確認する
    assert_equal File.binread(file_fixture("sample.png")), @post.image.read
  end

  test "image? は S3 アクセスを発生させなくなった" do
    assert @post.image?
    assert_empty @requests
  end

  test "image.size は S3 への HEAD リクエストを発生させる(変化なし)" do
    @post.image.size
    assert_head @requests
  end

  test "バリデーションを定義していないモデルの valid? は S3 アクセスを発生させなくなった" do
    # 3.1.x では CarrierWave 自動追加の integrity / processing / download バリデータの
    # スキップ判定(EachValidator#validate の value.blank?)で HEAD が発生していたが、
    # blank? がストレージに問い合わせなくなったため消えた
    @post.valid?
    assert_empty @requests
  end

  test "validates :image, presence: true のバリデーションは S3 アクセスを発生させなくなった" do
    post = PostWithImageValidation.create!(title: "sample", image: File.open(file_fixture("sample.png")))
    post = PostWithImageValidation.find(post.id)
    @requests.clear

    assert post.valid?
    assert_empty @requests
  ensure
    post&.image&.remove!
  end

  test "ファイルが実在しなくても presence バリデーションは valid になる(セマンティクスの変化)" do
    post = PostWithImageValidation.create!(title: "sample", image: File.open(file_fixture("sample.png")))
    post.image.file.delete # DB の識別子は残したまま、S3 上のオブジェクトだけを削除する
    post = PostWithImageValidation.find(post.id)
    @requests.clear

    # パッチ未適用の 3.1.x では blank? がストレージを見るためファイル不在なら
    # invalid(HEAD 5 回)だったが、パッチ適用後は識別子カラムがあれば valid となり、
    # S3 アクセスも発生しない
    assert post.valid?
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
