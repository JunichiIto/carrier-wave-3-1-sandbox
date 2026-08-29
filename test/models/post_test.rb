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

  private

  def assert_head(requests)
    assert requests.any? { |r| r.start_with?("HEAD ") }, "expected HEAD request, got: #{requests.inspect}"
  end
end
