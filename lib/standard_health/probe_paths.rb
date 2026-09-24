# frozen_string_literal: true

require "concurrent/map"

module StandardHealth
  # The engine's orchestrator-polled sub-paths. `config/routes.rb` draws its
  # probe routes FROM this list, so the probe-path pattern below cannot drift
  # from what the engine actually serves.
  #
  # The doctor tier (`/diagnostics/env`) is deliberately NOT here: it is
  # authed, called by on-call rather than on a timer, and does real work — it
  # belongs in request logs and APM.
  PROBE_ACTIONS = %w[alive ready].freeze

  # Where every consumer mounts the engine.
  DEFAULT_MOUNT_PATH = "/health"

  class << self
    # A Regexp matching the request paths an orchestrator polls on a timer:
    # the engine's probe routes under `mount`, the bare `mount` path (the
    # aggregate tier), and Rails' `/up`. Anchored at both ends — a sibling
    # route such as `/healthy-habits` or the doctor tier never matches — and
    # tolerant of one trailing slash.
    #
    # Hosts that mount the engine somewhere other than `/health` MUST pass
    # their prefix; the constant `PROBE_PATHS` assumes the default.
    #
    # @param mount [String] where the engine is mounted
    # @param up [Boolean] include Rails' `/up`
    # @param aggregate [Boolean] include the bare mount path (aggregate tier)
    # @param extra [Array<String>] additional exact paths (e.g. "/circuits")
    # @return [Regexp]
    def probe_path_pattern(mount: DEFAULT_MOUNT_PATH, up: true, aggregate: true, extra: [])
      prefix = normalize_mount(mount)
      paths = []
      paths << "/up" if up
      paths << (prefix.empty? ? "/" : prefix) if aggregate
      paths.concat(PROBE_ACTIONS.map { |action| "#{prefix}/#{action}" })
      paths.concat(Array(extra).map { |path| normalize_mount(path) })

      alternation = paths.uniq.map { |path| Regexp.escape(path.delete_suffix("/")) }.join("|")
      /\A(?:#{alternation})\/?\z/
    end

    # True when `path` is an orchestrator probe. Takes the same options as
    # `probe_path_pattern`; patterns are built once per option set.
    #
    #   StandardHealth.probe_path?(request.path)
    #   StandardHealth.probe_path?(env["PATH_INFO"], mount: "/_health")
    def probe_path?(path, **options)
      pattern = options.empty? ? PROBE_PATHS : probe_pattern_cache.compute_if_absent(options) { probe_path_pattern(**options) }
      path.to_s.match?(pattern)
    end

    private

    def normalize_mount(path)
      path = path.to_s
      path = "/#{path}" unless path.start_with?("/")
      path.delete_suffix("/")
    end

    def probe_pattern_cache
      @probe_pattern_cache ||= Concurrent::Map.new
    end
  end

  # The default probe pattern, for an engine mounted at `/health`:
  #
  #   /up, /health, /health/alive, /health/ready  (each with an optional trailing /)
  #
  # A drop-in for the `%r{\A/(up|health/(alive|ready))\z}` hosts copy-paste
  # into `silence_healthcheck_path`, `ssl_options` / `host_authorization`
  # excludes and Sentry `traces_sampler`s — plus the bare aggregate `/health`,
  # which is polled just as often. Pass `aggregate: false` to
  # `probe_path_pattern` for the old exact set.
  PROBE_PATHS = probe_path_pattern
end
