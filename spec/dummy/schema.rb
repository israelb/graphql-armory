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

  create_table :keyset_items do |t|
    t.integer :rank, null: false, default: 0
    t.string :name, null: false, default: ""
    t.decimal :amount, precision: 10, scale: 2, null: false, default: 0
    t.datetime :happened_at, precision: 6, null: false, default: "2026-01-01"
    t.float :score, null: false, default: 0
    t.string :note
  end

  create_table :notes do |t|
    t.references :account, null: false
    t.string :body
  end
end
