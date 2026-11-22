# frozen_string_literal: true

require "standard_health/env_spec"

module StandardHealth
  # Checks and env vars announced by OTHER gems, through a Rails load hook so
  # neither side needs a gemspec dependency on the other:
  #
  #   # in standard_id — no `require "standard_health"`
  #   ActiveSupport.on_load(:standard_health) do |health|
  #     health.contribute_check :standard_id_migrations, "StandardId::Checks::Migrations"
  #     health.contribute_env_vars "standard_id" do
  #       recommended :STANDARD_ID_OAUTH_SIGNING_KEY, description: "..."
  #       forbidden :STANDARD_ID_BYPASS_CODE, in: %w[production]
  #     end
  #   end
  #
  # standard_health runs `ActiveSupport.run_load_hooks(:standard_health,
  # StandardHealth.contributions)` once, when it is required. Hooks registered
  # before that run then; hooks registered after it run immediately. Either
  # way the block receives this registry, so load order between the gems does
  # not matter.
  #
  # The registry is a process-wide singleton (`StandardHealth.contributions`)
  # kept apart from `Configuration`, because the hooks run once per process
  # and `StandardHealth.reset_config!` (which app and gem specs call before
  # every example) must not lose what they contributed.
  #
  # Contributor-facing API: `#contribute_check` and `#contribute_env_vars`.
  # The readers below them are how `Configuration` consumes the registry.
  class Contributions
    # A check another gem offers to `Configuration#register_default_checks`.
    Check = Struct.new(:name, :klass, :critical, :timeout, :options, keyword_init: true)

    # Names `register_default_checks` owns outright. A contribution may not
    # take one: it would silently replace an app's database or queue gate.
    # (`audit_retention` is deliberately absent — standard_audit is expected
    # to contribute it and take over the hardcoded default.)
    RESERVED_CHECK_NAMES = %i[database solid_queue solid_cache].freeze

    def initialize
      @checks = {}
      @env_specs = {}
      @defaults_applied = false
    end

    # Offer a check to every app that calls `register_default_checks`. It
    # registers non-critical unless `critical: true`, and the app can still
    # opt out or override it per name, exactly like a built-in default:
    #
    #   c.register_default_checks standard_id_migrations: false
    #   c.register_default_checks standard_id_migrations: { critical: true }
    #
    # Pass `klass` as a String so the class is resolved when the check runs,
    # not when the hook fires (the contributing gem's constants may not be
    # loadable yet at that point). Same keywords as
    # `Configuration#register_check`. Re-contributing a name replaces it.
    #
    # Contribute when the gem is required (top level of its main file or
    # engine file). Under `Bundler.require` that is before any app
    # initializer. A check contributed after the app has already called
    # `register_default_checks` is NOT registered retroactively; a warning
    # says so.
    def contribute_check(name, klass, critical: false, timeout: nil, **options)
      name = name.to_sym
      if RESERVED_CHECK_NAMES.include?(name)
        raise ArgumentError,
              "#{name.inspect} is a standard_health default check and cannot be contributed; pick another name"
      end
      unless klass.is_a?(String) || klass.is_a?(Module)
        raise ArgumentError, "contribute_check(#{name.inspect}) needs a class or a class name String; got #{klass.inspect}"
      end

      if @defaults_applied
        warn "[standard_health] check #{name.inspect} was contributed after register_default_checks ran, " \
             "so it is not registered. Contribute checks when the gem is required."
      end

      @checks[name] = Check.new(name: name, klass: klass, critical: critical, timeout: timeout, options: options)
    end

    # Declare env vars the contributing gem reads. The block is the
    # `EnvSpec` DSL (`required` / `recommended` / `forbidden` / `group`), and
    # every entry is grouped under `contributor` in the audit. The
    # declarations join the app's `env_spec` on `/diagnostics/env` and in
    # `Checks::EnvSpecAudit`; an entry the app declares itself (same name)
    # wins over the gem's.
    #
    # `in:` takes plain environment names only (`in: %w[production]`).
    # Mode aliases such as `:deployed` or `:live` belong to the app, so a
    # Symbol `in:` or a `mode_alias` call raises `ArgumentError` here, when
    # the contributing gem loads.
    #
    # Re-contributing under the same `contributor` replaces its declarations.
    # Unlike checks, env vars are merged when the audit runs, so a late
    # contribution still shows up.
    def contribute_env_vars(contributor, &block)
      raise ArgumentError, "contribute_env_vars(#{contributor.inspect}) needs a block" unless block

      label = contributor.to_s
      spec = EnvSpec.new
      spec.group(label) { spec.instance_eval(&block) }
      validate_plain_modes!(label, spec)

      @env_specs[label] = spec
    end

    # @return [Array<Check>] in contribution order
    def checks
      @checks.values
    end

    # Every contributor's declarations as one spec, or nil when there are
    # none. Each var appears once; if two gems declare it, the gem that
    # contributed first wins.
    #
    # @return [EnvSpec, nil]
    def env_spec
      @env_specs.values.reduce { |merged, spec| merged.reverse_merge(spec) }
    end

    # Called by `Configuration#register_default_checks`, so a check
    # contributed after that point warns instead of silently not appearing.
    def defaults_applied!
      @defaults_applied = true
    end

    private

    def validate_plain_modes!(label, spec)
      unless spec.mode_aliases.empty?
        raise ArgumentError,
              "contribute_env_vars(#{label.inspect}) declares mode_alias " \
              "#{spec.mode_aliases.keys.map(&:inspect).join(", ")}; mode aliases belong to the app, " \
              "so use plain environment names (in: %w[production])"
      end

      aliased = spec.entries.select { |entry| entry.modes.is_a?(Symbol) }
      return if aliased.empty?

      raise ArgumentError,
            "contribute_env_vars(#{label.inspect}) uses mode alias(es) in `in:` for " \
            "#{aliased.map { |e| "#{e.name} (#{e.modes.inspect})" }.join(", ")}; mode aliases belong to " \
            "the app, so use plain environment names (in: %w[production])"
    end
  end
end
