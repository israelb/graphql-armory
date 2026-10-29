# frozen_string_literal: true

# Plain Pundit policies: they know nothing about graphql-armory.
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end
  end
end

class InvoicePolicy < ApplicationPolicy
  def read?
    record.account_id == user.account_id
  end

  def approve?
    user.admin? && record.account_id == user.account_id
  end

  def export?
    user.admin?
  end

  def manage?
    user.admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(account_id: user.account_id)
    end
  end
end

class AccountPolicy < ApplicationPolicy
  def read?
    record.id == user.account_id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(id: user.account_id)
    end
  end
end

class UserPolicy < ApplicationPolicy
  def read?
    record.account_id == user.account_id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(account_id: user.account_id)
    end
  end
end

class NotePolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def read?
    record.account_id == user.account_id
  end
end

class OddPolicy < ApplicationPolicy
  def read?
    "yes"
  end
end
