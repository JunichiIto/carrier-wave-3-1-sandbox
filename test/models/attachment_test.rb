require "test_helper"

# 条件付き version(画像のときだけ preview を生成)が S3(MinIO)への
# HTTP リクエストに与える影響を Excon のインストルメンテーションで観測する。
# 関連 issue: https://github.com/carrierwaveuploader/carrierwave/issues/1926
class AttachmentTest < ActiveSupport::TestCase
  # fog の接続は遅延生成なので、最初の接続が作られる前にここで設定すれば全リクエストに効く
  Excon.defaults[:instrumentor] = ActiveSupport::Notifications

  setup do
    @requests = []
    @subscriber = ActiveSupport::Notifications.subscribe("excon.request") do |_name, _start, _finish, _id, payload|
      @requests << "#{payload[:method].to_s.upcase} #{payload[:path]}"
    end
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscriber)
  end

  test "生成済みの条件付き version の preview.present? は true(HEAD 1 回)" do
    attachment = create_fresh_attachment("sample.png")

    # HEAD は親ファイルへの 1 回のみ(if: :image_file? の条件評価で content_type を
    # 取得するため)。モンキーパッチ適用後の blank? はストレージに問い合わせないため、
    # 3.1 系と違って version ファイル自体の存在確認は発生しない
    assert attachment.file.preview.present?
    assert_head @requests
  ensure
    attachment&.file&.remove!
  end

  test "生成済みの条件付き version の preview.exists? は true(HEAD 2 回)" do
    attachment = create_fresh_attachment("sample.png")

    # ストレージ実在確認は新設の exists? が担う。1 回目の HEAD は条件評価
    # (content_type 取得)、2 回目が version ファイル自体の存在確認
    assert attachment.file.preview.exists?
    assert_head @requests, count: 2
  ensure
    attachment&.file&.remove!
  end

  test "未生成の条件付き version の preview.present? は false(条件評価の HEAD 1 回)" do
    attachment = create_fresh_attachment("sample.txt")

    # HEAD は親ファイルへの 1 回のみ(条件評価で content_type を取得 → 画像でないため
    # version は組み立てられず、version パスへの問い合わせは発生しない)
    assert_not attachment.file.preview.present?
    assert_head @requests
  ensure
    attachment&.file&.remove!
  end

  test "条件付き version を定義すると file_url でも条件評価の HEAD が発生する" do
    attachment = create_fresh_attachment("sample.png")

    # version なしのアップローダー(ImageUploader)では url 生成は S3 アクセスゼロだが、
    # 条件付き version があると初回アクセス時の条件評価で親ファイルへの HEAD が発生する
    attachment.file_url
    assert_head @requests
  ensure
    attachment&.file&.remove!
  end

  test "S3 上の preview だけが消えている場合、present? は true だが exists? は false を返す" do
    # 「条件は true なのに version の実体がない」状態は、version を後から
    # アップローダーに追加した(recreate_versions! 未実行)、version の条件や
    # 名前を後から変更した、store! や recreate_versions! が部分失敗した、
    # などの通常の運用で自然に発生する。ここでは S3 上のオブジェクトを
    # 直接削除してその状態を再現する
    attachment = Attachment.create!(file: File.open(file_fixture("sample.png")))
    attachment.file.preview.file.delete # DB はそのまま、S3 上の preview オブジェクトだけを削除する
    attachment = Attachment.find(attachment.id)
    @requests.clear

    # パッチ適用後の present? は「割り当ての有無」なので、実体がなくても true を返す
    # (3.1 系はストレージ確認により false。3.0 系も true だが確認手段がなかった)
    assert attachment.file.preview.present?
    assert_head @requests # 条件評価の HEAD 1 回のみ

    # 実在確認は新設の exists? で明示的に行う。条件評価は直前の present? で
    # 済んでいる(同一インスタンス内でメモ化される)ため、HEAD は version の
    # 404 確認の 1 回のみ
    @requests.clear
    assert_not attachment.file.preview.exists?
    assert_head @requests
  ensure
    attachment&.file&.remove!
  end

  private

  # アップロード時の状態をキャッシュしていないフレッシュなインスタンスを返し、計測を初期化する
  def create_fresh_attachment(fixture_name)
    attachment = Attachment.create!(file: File.open(file_fixture(fixture_name)))
    Attachment.find(attachment.id).tap { @requests.clear }
  end

  def assert_head(requests, count: 1)
    head_count = requests.count { |r| r.start_with?("HEAD ") }
    assert_equal count, head_count, "expected #{count} HEAD request(s), got: #{requests.inspect}"
  end
end
