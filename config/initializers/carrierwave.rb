CarrierWave.configure do |config|
  config.storage = :fog
  config.fog_credentials = {
    provider:              "AWS",
    aws_access_key_id:     ENV.fetch("MINIO_ACCESS_KEY", "minioadmin"),
    aws_secret_access_key: ENV.fetch("MINIO_SECRET_KEY", "minioadmin"),
    region:                ENV.fetch("MINIO_REGION", "us-east-1"), # ダミー値(署名 v4 に必須。MinIO は無視する)
    endpoint:              ENV.fetch("MINIO_ENDPOINT", "http://localhost:9000"),
    path_style:            true # MinIO では必須(バケットをサブドメインでなくパスに置く)
  }
  config.fog_directory = ENV.fetch("MINIO_BUCKET") do
    Rails.env.test? ? "carrierwave-test" : "carrierwave-dev"
  end
  config.fog_public = true
end
