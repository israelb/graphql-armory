# frozen_string_literal: true

# Helpers for the black-box security suite in spec/security: every example sends a real query
# as one user and looks only at what the client would see.
module SecurityHelpers
  def world
    @world ||= Dummy::World.build
  end

  def telemetry
    @telemetry ||= []
  end

  # Runs +query+ as +user+ against a schema in the given denial mode. Extra keywords are the root value.
  def as(user, query, mode: :null, variables: {}, **root)
    sink = ->(signal, data) { telemetry << [signal, data] }
    schema = IntegrationSchema.build(on_unauthorized: mode, sinks: [sink])

    execute_query(schema, query, variables: variables, context: { current_user: user },
                                 root_value: IntegrationSchema::Root.new(**root))
  end

  # The response to looking up +id+ with a root field, as a user who may not own it.
  def lookup(user, id, mode: :null)
    as(user, "query($id: ID!) { invoice(id: $id) { number internalNotes } }", mode: mode, variables: { "id" => id.to_s })
  end

  def load_by(user, id, mode: :null)
    as(user, "query($id: ID!) { invoiceViaRef(invoiceId: $id) { number internalNotes } }", mode: mode,
                                                                                            variables: { "id" => id.to_s })
  end

  def missing_id
    999_999
  end
end

RSpec.configure do |config|
  config.include SecurityHelpers, file_path: %r{spec/security/}
end
