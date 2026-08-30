class CreateAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :attachments do |t|
      t.string :file

      t.timestamps
    end
  end
end
