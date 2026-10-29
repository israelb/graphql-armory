# frozen_string_literal: true

ActiveRecord::Schema.verbose = false

ActiveRecord::Schema.define do
  create_table :accounts do |t|
    t.string :name, null: false
  end

  create_table :users do |t|
    t.references :account, null: false
    t.string :name, null: false
    t.boolean :admin, null: false, default: false
  end

  create_table :invoices do |t|
    t.references :account, null: false
    t.string :number, null: false
    t.string :internal_notes
  end

  create_table :credits do |t|
    t.references :account, null: false
  end

  create_table :notes do |t|
    t.references :account, null: false
    t.string :body
  end
end
