# frozen_string_literal: true

module StandardHealth
  # Settings for the built-in HTTP Basic gate on `/diagnostics/env`, set via
  # `config.diagnostics_basic_auth`. See `DiagnosticsAuthentication` for the
  # request-time behaviour.
  #
  # Every consumer app carried a near-identical `StandardHealthHostController`
  # (ActionController::API + HTTP Basic against ADMIN_BASIC_AUTH_*) wired via
  # `diagnostics_parent_controller`. This is that controller, owned once.
  #
  # Credentials are resolved PER REQUEST, never captured at boot: a value may
  # be a String or anything responding to `call` (a lambda reading ENV, Rails
  # credentials, `Current.config`, ...). Rotating the secret therefore needs
  # no restart, and a host whose credential source isn't ready at initializer
  # time still works.
  class DiagnosticsBasicAuth
    DEFAULT_USERNAME_ENV = "ADMIN_BASIC_AUTH_USERNAME"
    DEFAULT_PASSWORD_ENV = "ADMIN_BASIC_AUTH_PASSWORD"
    DEFAULT_REALM = "Health Diagnostics"

    KEYS = %i[username password realm allow_unconfigured].freeze

    attr_reader :username, :password, :realm, :allow_unconfigured

    # Builds settings from what the host assigned.
    #
    #   nil / false  -> nil (gate off; the pre-0.6.0 behaviour)
    #   true         -> defaults (ADMIN_BASIC_AUTH_USERNAME / _PASSWORD)
    #   Hash         -> defaults overridden by the given keys
    def self.build(value)
      case value
      when nil, false then nil
      when true then new
      when Hash then new(**value.transform_keys(&:to_sym))
      when DiagnosticsBasicAuth then value
      else
        raise ArgumentError,
              "diagnostics_basic_auth must be true, false, nil or a Hash of #{KEYS.join('/')}; got #{value.class}"
      end
    end

    def initialize(username: -> { ENV[DEFAULT_USERNAME_ENV] },
                   password: -> { ENV[DEFAULT_PASSWORD_ENV] },
                   realm: DEFAULT_REALM,
                   allow_unconfigured: false)
      @username = username
      @password = password
      @realm = realm
      @allow_unconfigured = allow_unconfigured
    end

    # @return [String] the expected username for this request ("" when unset)
    def expected_username
      resolve(@username)
    end

    # @return [String] the expected password for this request ("" when unset)
    def expected_password
      resolve(@password)
    end

    # FAIL CLOSED by default. An unset secret is what a broken deploy looks
    # like, not a request to publish env state. `allow_unconfigured` (a
    # boolean or a callable, e.g. `-> { Rails.env.local? }`) opts a
    # credential-less environment into passing through.
    def allow_unconfigured?
      !!resolve_raw(@allow_unconfigured)
    end

    # Constant-time on both halves, over digests so differing lengths don't
    # short-circuit (or raise). `&` rather than `&&` so the password compare
    # runs even when the username is wrong.
    def authenticate(user, pass)
      digest_compare(user, expected_username) & digest_compare(pass, expected_password)
    end

    private

    def resolve(value)
      resolve_raw(value).to_s
    end

    def resolve_raw(value)
      value.respond_to?(:call) ? value.call : value
    end

    def digest_compare(given, expected)
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(given.to_s), Digest::SHA256.hexdigest(expected.to_s)
      )
    end
  end
end
