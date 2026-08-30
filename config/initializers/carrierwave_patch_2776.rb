# CarrierWave 3.1 系で present? / blank? / valid? などが S3 への HEAD リクエストを
# 発生させる問題(issue #2776)に対する master の修正コミットを 3.1.3 に移植する
# モンキーパッチ。
# https://github.com/carrierwaveuploader/carrierwave/commit/f635d88b9debeda27b25148856ca5e0faa186d17
#
# 修正込みのバージョン(4.0 予定)がリリースされたら、このファイルごと削除して
# bundle update carrierwave すること。

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
      # キャッシュ名が指す先のキャッシュは消えていることがあるため検証する。
      # キャッシュはローカルなので安価(リモートストレージへの問い合わせは発生しない)
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

      # Fog::Storage::XXX::File#body could return the source file which was uploaded to the remote server.
      return read_source_file if ::File.exist?(file_body.path)

      # If the source file doesn't exist, the remote content is read
      # file のメモ化を defined? 方式に変えたことに合わせ、本家コミットと同じく
      # @file = nil ではなく remove_instance_variable でメモ化を解除する
      # (nil を代入すると「nil がメモ化された状態」になるため)。
      # なお fog-aws では body が String で返るためこの分岐には到達しないことを
      # 実測で確認済み(body が ::File を返しうる他の fog プロバイダ向けの移植)
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
