# frozen_string_literal: true

# Plain CanCanCan abilities: they know nothing about graphql-armory.
class Ability
  include CanCan::Ability

  def initialize(user)
    can :read, Invoice, account_id: user.account_id
    can :manage, Invoice, account_id: user.account_id if user.admin?
    can :export, Invoice if user.admin?
    can :read, Account, id: user.account_id
  end
end

# A rule defined with a block only: it cannot be turned into SQL, so `accessible_by` raises.
class BlockAbility
  include CanCan::Ability

  def initialize(user)
    can(:read, Invoice) { |invoice| invoice.account_id == user.account_id }
  end
end

# `can :read, Invoice, [:number]`: an attribute rule, so `can?(:read, invoice)` is true for the whole object.
class AttributeAbility
  include CanCan::Ability

  def initialize(user)
    can :read, Invoice, [:number], account_id: user.account_id
  end
end
