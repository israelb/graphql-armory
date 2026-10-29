# frozen_string_literal: true

class Account < ActiveRecord::Base
  has_many :users
  has_many :invoices
end

class User < ActiveRecord::Base
  belongs_to :account
end

class Invoice < ActiveRecord::Base
  belongs_to :account
end

# Its policy is chosen with `policy_class`, not by name.
class Credit < ActiveRecord::Base
  belongs_to :account

  def self.policy_class
    InvoicePolicy
  end
end

# Its policy has no Scope and no manage?.
class Note < ActiveRecord::Base
  belongs_to :account
end

# No policy exists for it.
class Ghost
end

# Its policy answers with something that is not a boolean.
class Odd
end
