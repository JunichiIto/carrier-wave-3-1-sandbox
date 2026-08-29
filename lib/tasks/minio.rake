namespace :minio do
  desc "MinIO を起動し、ヘルシーになってバケット作成が完了するまで待つ"
  task :up do
    # createbuckets は exit 0 でも `up -d --wait` 全体を失敗扱いにしてしまうため、
    # minio だけを --wait で待ち、バケット作成は run --rm で同期実行する(冪等)
    sh "docker compose up -d --wait minio"
    sh "docker compose run --rm createbuckets"
  end
end

desc "MinIO を起動して S3 アクセス検証テストを実行する"
task verify: "minio:up" do
  sh "bin/rails test test/models/post_test.rb"
end
