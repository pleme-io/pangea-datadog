# frozen_string_literal: true

require_relative 'absorb/client'
require_relative 'absorb/capture'
require_relative 'absorb/normalize'
require_relative 'absorb/config'
require_relative 'absorb/rules'
require_relative 'absorb/classify'
require_relative 'absorb/engines/timeseries_grid'
require_relative 'absorb/emit'
require_relative 'absorb/verify'
require_relative 'absorb/receipt'
require_relative 'absorb/roundtrip'

module Pangea
  module Datadog
    # Absorbs a live Datadog estate into typed Pangea code and proves the two
    # agree.
    #
    #   validate  config          -> ok or a named error
    #   capture   live API        -> estate/     lossless snapshot
    #   classify  estate/         -> report      what is worth adopting
    #   emit      estate/         -> generated/  typed Pangea Ruby
    #   verify    generated/      vs estate/     state match, exit 0 or 1
    #
    # The staircase the verbs implement:
    #
    #   rung 1  raw capture on disk                exact,  not refactorable
    #   rung 2  typed resources, hash widgets      exact,  partly refactorable
    #   rung 3  archetype engines from config      proven, fully refactorable
    #
    # Each rung must pass verify before the next is attempted, so a refactor can
    # never quietly change what the estate says.
    #
    # The engine is general. Every organisation-specific decision lives in the
    # config file, and Rules.none is what the engine believes without one.
    module Absorb
      module_function

      def config(path)
        Config.load(path)
      end

      def rules_for(path)
        path ? Rules.from(Config.load(path)) : Rules.none
      end

      def capture(root:, config_path: nil, account: nil, site: nil, progress: nil, kinds: nil)
        cfg = config_path ? Config.load(config_path) : nil
        client =
          if cfg
            Client.from_config(cfg, site: site)
          else
            Client.for_account(account, site: site || Client::DEFAULT_SITE)
          end
        Capture.run(client: client, root: root, progress: progress,
                    kinds: kinds || Capture::DEFAULT_KINDS)
      end

      def emit(root:, out_dir:, config_path: nil)
        Emit.new(capture: Capture.new(root), out_dir: out_dir, rules: rules_for(config_path)).run
      end

      # Proves terraform plans to "No changes" against the LIVE objects, which
      # is the claim `verify` structurally cannot make. Read-only: import and
      # plan are both GET against Datadog.
      def roundtrip(root:, provider_dir:, config_path: nil, kinds: nil, per_kind: 1,
                    terraform: 'terraform')
        cfg   = config_path ? Config.load(config_path) : nil
        creds = credentials_for(cfg)

        rt = Roundtrip.new(capture: Capture.new(root), provider_dir: provider_dir,
                           terraform: terraform, site: cfg&.site || Client::DEFAULT_SITE,
                           rules: cfg ? Rules.from(cfg) : Rules.none)
        rt.run(kinds: kinds || Roundtrip::KINDS.keys, per_kind: per_kind, credentials: creds)
      end

      # Records the provider's own normalized body for dashboards that cannot
      # plan clean from the API payload alone. OPT-IN: nothing calls this unless
      # the operator asks, and the default emit path is unchanged.
      def reconcile(root:, provider_dir:, config_path: nil, terraform: 'terraform',
                    only_failing: true, kinds: nil)
        cfg   = config_path ? Config.load(config_path) : nil
        creds = credentials_for(cfg)
        rt = Roundtrip.new(capture: Capture.new(root), provider_dir: provider_dir,
                           terraform: terraform, site: cfg&.site || Client::DEFAULT_SITE,
                           rules: cfg ? Rules.from(cfg) : Rules.none)
        rt.reconcile(credentials: creds, only_failing: only_failing,
                     kinds: kinds || [:dashboards])
      end

      def verify(root:, out_dir:)
        Verify.new(capture: Capture.new(root), out_dir: out_dir).run
      end

      def credentials_for(cfg)
        if cfg&.sops?
          require 'pangea/secrets'
          Pangea::Secrets.configure(sops_file: cfg.sops_file, sops_nix_dir: cfg.sops_nix_dir)
          { api_key: Pangea::Secrets.resolve(cfg.api_key_secret),
            app_key: Pangea::Secrets.resolve(cfg.app_key_secret) }
        else
          { api_key: Client.read_secret(cfg&.api_key_path.to_s, 'DD_API_KEY'),
            app_key: Client.read_secret(cfg&.app_key_path.to_s, 'DD_APP_KEY') }
        end
      end

      # A plain accounting of the estate. Deliberately not a judgement: it reports
      # provenance and tier so the operator decides what to adopt.
      def classify(root:, config_path: nil)
        capture = Capture.new(root)
        rules   = rules_for(config_path)
        twins   = rules.dedupe_identical? ? Classify.twin_index(capture) : {}

        monitors  = Hash.new(0)
        corrupted = 0
        capture.each(:monitors) do |_, payload|
          monitors[rules.provenance_of(payload) || 'unclassified'] += 1
          corrupted += 1 if Classify.tags_corrupted?(payload)
        end

        dashboards = Hash.new(0)
        families   = Hash.new(0)
        capture.each(:dashboards) do |id, payload|
          tier = Classify.dashboard_tier(payload, id: id, rules: rules, twins: twins)
          dashboards[tier] += 1
          arch = rules.archetype_for(payload['title'])
          families[arch.name] += 1 if arch && tier != Classify::TIER_RETIRE
        end

        {
          monitors: monitors,
          monitors_with_corrupted_tags: corrupted,
          dashboards: dashboards,
          archetype_families: families
        }
      end
    end
  end
end
