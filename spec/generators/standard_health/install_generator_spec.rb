# frozen_string_literal: true

require "rails_helper"
require "rails/generators"
require "generators/standard_health/install/install_generator"

RSpec.describe StandardHealth::Generators::InstallGenerator do
  let(:destination_root) { File.expand_path("../../../tmp/generator_test", __dir__) }

  before do
    FileUtils.rm_rf(destination_root)
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
    File.write(File.join(destination_root, "config/routes.rb"), <<~ROUTES)
      Rails.application.routes.draw do
        root "home#index"
      end
    ROUTES
  end

  after { FileUtils.rm_rf(destination_root) }

  def run_generator(options = {})
    generator = described_class.new([], options)
    generator.destination_root = destination_root
    silence_stream { generator.invoke_all }
  end

  # The generator says_status to stdout; keep the spec output readable.
  def silence_stream
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def initializer_path
    File.join(destination_root, "config/initializers/standard_health.rb")
  end

  def routes_content
    File.read(File.join(destination_root, "config/routes.rb"))
  end

  describe "the initializer" do
    it "is created" do
      run_generator

      expect(File.exist?(initializer_path)).to be true
    end

    it "configures checks and an env spec" do
      run_generator
      content = File.read(initializer_path)

      expect(content).to include("StandardHealth.configure")
      expect(content).to include("config.register_check :database, StandardHealth::Checks::ActiveRecord, critical: true")
      expect(content).to include("config.env_spec = StandardHealth::EnvSpec.define")
      expect(content).to include("mode_alias :deployed")
    end

    it "carries the frozen string literal magic comment (gem-wide convention)" do
      run_generator

      expect(File.read(initializer_path).lines.first).to eq("# frozen_string_literal: true\n")
    end

    it "documents the aggregate-route ordering requirement" do
      run_generator
      content = File.read(initializer_path)

      expect(content).to include("ROUTE ORDERING")
      expect(content).to include("must be drawn")
      expect(content).to include("BEFORE the mount")
      expect(content).to include("silently has no aggregate tier")
    end

    it "shows the opt-in checks as commented-out, never registered by default" do
      run_generator
      content = File.read(initializer_path)

      expect(content).to include("# config.register_check :solid_cable, StandardHealth::Checks::SolidCable")
      expect(content).to include("# config.register_check :env_spec, StandardHealth::Checks::EnvSpecAudit")
    end

    it "demonstrates the forbidden level and expected_value assertion" do
      run_generator
      content = File.read(initializer_path)

      expect(content).to include("forbidden :DEMO_MODE_ENABLED, in: :live")
      expect(content).to include("expected_value: \"false\"")
    end
  end

  describe "the routes mount" do
    it "mounts the engine" do
      run_generator

      expect(routes_content).to include('mount StandardHealth::Engine => "/health", as: :standard_health')
    end

    it "carries the ordering warning and a commented aggregate route" do
      run_generator

      expect(routes_content).to include("ORDERING MATTERS")
      expect(routes_content).to include('# get "/health", to: "health_aggregate#show"')
    end

    it "leaves the existing routes intact" do
      run_generator

      expect(routes_content).to include('root "home#index"')
    end

    it "draws the commented aggregate route ABOVE the mount" do
      run_generator
      content = routes_content

      expect(content.index('# get "/health"')).to be < content.index("mount StandardHealth::Engine")
    end

    it "still mounts when the host already draws its own aggregate route" do
      File.write(File.join(destination_root, "config/routes.rb"), <<~ROUTES)
        Rails.application.routes.draw do
          get "/health", to: "health_aggregate#show"
        end
      ROUTES

      run_generator

      expect(routes_content).to match(/^\s*mount StandardHealth::Engine/)
      expect(routes_content).to include('get "/health", to: "health_aggregate#show"')
    end

    it "skips gracefully when config/routes.rb does not exist" do
      FileUtils.rm(File.join(destination_root, "config/routes.rb"))

      expect { run_generator }.not_to raise_error
      expect(File.exist?(initializer_path)).to be true
    end
  end

  describe "idempotency" do
    it "does not mount the engine twice on a re-run" do
      run_generator
      run_generator

      expect(routes_content.scan("mount StandardHealth::Engine").size).to eq(1)
    end

    # A commented example must NOT read as a live mount. Getting this wrong
    # leaves the host with no health routes at all, and a reassuring
    # "already mounted, skipping" explaining why that was fine.
    it "does NOT treat a commented-out mount as already mounted" do
      File.write(File.join(destination_root, "config/routes.rb"), <<~ROUTES)
        Rails.application.routes.draw do
          # mount StandardHealth::Engine => "/health"
        end
      ROUTES

      run_generator

      expect(routes_content).to match(/^\s*mount StandardHealth::Engine/)
    end

    it "leaves a hand-mounted engine alone" do
      File.write(File.join(destination_root, "config/routes.rb"), <<~ROUTES)
        Rails.application.routes.draw do
          mount StandardHealth::Engine, at: "/health"
        end
      ROUTES

      run_generator

      expect(routes_content.scan(/mount\s+StandardHealth::Engine/).size).to eq(1)
    end

    it "does not overwrite an existing initializer without --force" do
      File.write(initializer_path, "# hand-written\n")

      run_generator

      expect(File.read(initializer_path)).to eq("# hand-written\n")
    end

    it "overwrites an existing initializer with --force" do
      File.write(initializer_path, "# hand-written\n")

      run_generator(force: true)

      expect(File.read(initializer_path)).to include("StandardHealth.configure")
    end
  end

  describe "skip flags" do
    it "--skip-initializer writes no initializer but still mounts" do
      run_generator(skip_initializer: true)

      expect(File.exist?(initializer_path)).to be false
      expect(routes_content).to include("mount StandardHealth::Engine")
    end

    it "--skip-routes writes the initializer but does not touch routes" do
      run_generator(skip_routes: true)

      expect(File.exist?(initializer_path)).to be true
      expect(routes_content).not_to include("mount StandardHealth::Engine")
    end
  end
end
