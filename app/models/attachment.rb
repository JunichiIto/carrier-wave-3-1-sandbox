class Attachment < ApplicationRecord
  mount_uploader :file, FileUploader
end
