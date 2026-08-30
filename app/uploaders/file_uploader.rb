class FileUploader < CarrierWave::Uploader::Base
  include CarrierWave::Vips

  storage :fog

  def store_dir
    "uploads/#{model.class.to_s.underscore}/#{mounted_as}/#{model.id}"
  end

  # 画像ファイルのときだけ生成される条件付き version(issue #1926 の検証用)
  version :preview, if: :image_file? do
    process resize_to_fit: [ 200, 200 ]
  end

  private

  def image_file?(new_file)
    new_file.content_type&.start_with?("image/")
  end
end
