# frozen_string_literal: true

require "rails/generators"

module StandardHealth
  module Generators
    # Installs StandardHealth in a host Rails application.
    #
    # Writes `config/initializers/standard_health.rb` and mounts the engine in
    # `config/routes.rb`.
    #
    # The routes step exists because of a failure mode that is otherwise
    # invisible: the engine only draws SUB-paths (`/alive`, `/ready`,
    # `/diagnostics/env`), so an app that mounts it and expects an aggregate
    # `GET /health` silently has no aggregate tier — no boot error, no failing
    # route spec. The generated block carries the ordering requirement as a
    # comment right where someone will read it.
    #
    # Idempotent: re-running skips pieces already installed. `--skip-*` opts
    # out of individual steps; `--force` overwrites an existing initializer.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      INITIALIZER_PATH = "config/initializers/standard_health.rb"
      ROUTES_PATH = "config/routes.rb"

      desc <<~DESC
        Installs StandardHealth. By default this:
          * writes config/initializers/standard_health.rb
          * mounts StandardHealth::Engine in config/routes.rb, with the
            aggregate-route ordering requirement noted inline

        Use --skip-* flags to opt out of individual steps when re-running on an
        existing install. The generator is idempotent — already-installed
        pieces are skipped with a clear message. Pass --force to overwrite an
        existing initializer.
      DESC

      class_option :skip_initializer, type: :boolean, default: false,
        desc: "Do not write #{INITIALIZER_PATH}"
      class_option :skip_routes, type: :boolean, default: false,
        desc: "Do not mount the engine in #{ROUTES_PATH}"
      class_option :force, type: :boolean, default: false,
        desc: "Overwrite #{INITIALIZER_PATH} if it already exists"

      def copy_initializer
        if options[:skip_initializer]
          say_status("skip", "#{INITIALIZER_PATH} (--skip-initializer)", :yellow)
          return
        end

        if File.exist?(File.join(destination_root, INITIALIZER_PATH)) && !options[:force]
          say_status("identical", "#{INITIALIZER_PATH} (already exists; pass --force to overwrite)", :blue)
          return
        end

        template "initializer.rb.erb", INITIALIZER_PATH, force: options[:force]
      end

      def mount_engine
        if options[:skip_routes]
          say_status("skip", "#{ROUTES_PATH} (--skip-routes)", :yellow)
          return
        end

        unless routes_file_exists?
          say_status("skip", "#{ROUTES_PATH} not found; mount the engine manually", :yellow)
          return
        end

        if already_mounted?
          say_status("identical", "#{ROUTES_PATH} (engine already mounted), skipping", :blue)
          return
        end

        route(routes_snippet)

        return unless aggregate_route_drawn?

        # `route` prepends, so a host that already draws its own `GET /health`
        # ends up with the mount ABOVE it. That still WORKS — the engine draws
        # no bare `/health`, so its router returns X-Cascade: pass and the
        # outer route matches (there is a spec pinning this). But it reads
        # backwards against the documented ordering, so say so rather than
        # leaving them to wonder.
        say_status(
          "review",
          "#{ROUTES_PATH}: the mount was prepended ABOVE your existing `GET /health`. " \
          "It still resolves via route cascading, but move the mount below it to match " \
          "the documented ordering.",
          :yellow
        )
      end

      no_commands do
        def routes_file_exists?
          File.exist?(File.join(destination_root, ROUTES_PATH))
        end

        def routes_source
          File.read(File.join(destination_root, ROUTES_PATH))
        end

        # Match the mount however it was written — `=>` or a trailing `at:` —
        # so a hand-mounted app isn't given a duplicate.
        #
        # ANCHORED PER LINE, and that matters: an unanchored match would treat
        # a commented example (`# mount StandardHealth::Engine => "/health"`)
        # as a live mount and skip the install, leaving the host with no health
        # routes at all and a "already mounted, skipping" message explaining
        # why it was fine.
        def already_mounted?
          routes_source.each_line.any? do |line|
            line.match?(/\A\s*mount\s+StandardHealth::Engine/)
          end
        end

        # Does the host already draw its own aggregate `GET /health`? Same
        # per-line anchoring, for the same reason.
        def aggregate_route_drawn?
          routes_source.each_line.any? do |line|
            line.match?(%r{\A\s*(?:get|match)\s+["']/health["']})
          end
        end

        # `route` prepends, so this block lands at the top of the draw block.
        # The aggregate line is commented rather than generated live: the
        # engine ships no aggregate controller (the tier is the host's job,
        # and its target is host-specific — often standard_circuit's), so
        # generating a route to a controller that does not exist would break
        # boot. The comment is the deliverable here.
        def routes_snippet
          <<~ROUTES
            # StandardHealth — liveness, readiness and the env doctor.
            #
            # ORDERING MATTERS. The aggregate `GET /health` must be drawn
            # BEFORE the mount below. The engine draws only sub-paths
            # (/alive, /ready, /diagnostics/env), so an app that mounts first
            # and relies on the engine to serve the aggregate tier silently
            # has NO aggregate tier — no boot error, no failing route spec.
            #
            # Uncomment and point at your aggregate controller:
            # get "/health", to: "health_aggregate#show"
            mount StandardHealth::Engine => "/health", as: :standard_health
          ROUTES
        end
      end
    end
  end
end
