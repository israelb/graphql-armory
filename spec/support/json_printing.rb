# frozen_string_literal: true

# Some graphql versions (2.4, 2.5) pass `quirks_mode:` to json, which json 3.1 refuses: they cannot print a String value
# (in `to_definition`, `defaultValue` or an invalid-variable message). Asked once, by trying, never from the version number.
module ArmoryJsonPrinting
  def self.prints_strings?
    return @prints_strings if defined?(@prints_strings)

    @prints_strings = begin
      GraphQL::Language.serialize("x")
      true
    rescue ArgumentError
      false
    end
  end
end
