# frozen_string_literal: true

require 'tmpdir'

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
require_relative 'absorb/audit'
require_relative 'absorb/census'

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

      # The regression oracle as ONE call: emit from the capture, then prove the
      # emitted code says what the capture says.
      #
      # OFFLINE BY CONSTRUCTION. It reads a capture off disk and touches no
      # Datadog API, so it is safe to run in CI, on a laptop, or anywhere the
      # credentials are not. Everything that talks to Datadog is a different
      # verb, deliberately.
      #
      # Emits to a TEMPORARY directory unless told otherwise. A run that emits
      # over the previous output and then fails leaves a half-written tree that
      # the next run would happily verify against -- the gate would be checking
      # its own debris.
      GateError = Class.new(StandardError)

      def gate(root:, config_path: nil, out_dir: nil)
        # A gate that passes on an absent or empty capture is a gate that passes
        # when the capture step silently failed -- the exact false green this
        # whole project exists to prevent. Nothing to check is "could not
        # answer" (exit 2), never "the answer is yes" (exit 0).
        capture = Capture.new(root)
        raise GateError, "no capture at #{root}" unless capture.exist?
        raise GateError, "capture at #{root} holds no objects" if capture.empty?

        return gate_in(root, config_path, out_dir) if out_dir

        Dir.mktmpdir('absorb-gate-') { |dir| gate_in(root, config_path, dir) }
      end

      def gate_in(root, config_path, dir)
        emit(root: root, out_dir: dir, config_path: config_path)
        verify(root: root, out_dir: dir)
      end

      # A correctness audit of the captured estate. Read-only and OFFLINE --
      # computed from a capture already on disk, no API call, nothing to
      # approve. See Audit for why a broken monitor and a silent one are
      # counted differently.
      # Read-only and counts only -- see Census for why it must never persist
      # what it reads.
      def census(config_path: nil, account: nil, site: nil)
        cfg = config_path ? Config.load(config_path) : nil
        client =
          if cfg
            Client.from_config(cfg, site: site)
          else
            Client.for_account(account, site: site || Client::DEFAULT_SITE)
          end
        Census.run(client: client, covered: Emit::ADDRESS_SHARDS.keys.size)
      end

      def audit(root:)
        Audit.run(Capture.new(root))
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
          archetype_families: families,
          other_kinds: other_kinds(capture)
        }
      end

      # Everything captured beyond monitors and dashboards, with WHY anything is
      # left out.
      #
      # classify is the verb someone runs first to see what adoption touches,
      # and it reported only two of the nine captured kinds -- so it understated
      # the scope and, worse, hid the deliberate exclusions, which are the part
      # an approver most needs to see. A skip that nobody can see reads as an
      # oversight.
      def other_kinds(capture)
        {
          slos: simple_count(capture, :slos),
          downtimes: simple_count(capture, :downtimes),
          logs_pipelines: pipeline_split(capture),
          logs_metrics: simple_count(capture, :logs_metrics),
          logs_indexes: simple_count(capture, :logs_indexes),
          teams: simple_count(capture, :teams),
          roles: role_split(capture),
          rum_applications: simple_count(capture, :rum_applications),
          apm_retention_filters: apm_split(capture),
          dashboard_lists: simple_count(capture, :dashboard_lists),
          powerpacks: powerpack_split(capture)
        }.reject { |_, value| value.nil? }
      end

      def simple_count(capture, kind)
        count = capture.ids(kind).size
        count.zero? ? nil : { captured: count, emitted: count }
      end

      # One endpoint, two resources: a read-only pipeline is Datadog's own and
      # becomes an integration pipeline carrying nothing but its on/off switch.
      def pipeline_split(capture)
        ids = capture.ids(:logs_pipelines)
        return nil if ids.empty?

        read_only = ids.count { |id| Normalize.logs_pipeline_read_only?(capture.read(:logs_pipelines, id)) }
        { captured: ids.size, emitted: ids.size,
          custom: ids.size - read_only, datadog_integration: read_only }
      end

      # Datadog ships Admin / Standard / Read Only into every account and the
      # provider models them not at all, so they are not adoptable.
      def role_split(capture)
        ids = capture.ids(:roles)
        return nil if ids.empty?

        managed = ids.count { |id| Normalize.role_managed?(capture.read(:roles, id)) }
        { captured: ids.size, emitted: ids.size - managed,
          skipped_datadog_managed: managed }
      end

      # The provider accepts one filter_type and rejects the rest at validate,
      # so a default filter cannot be emitted as anything.
      def apm_split(capture)
        ids = capture.ids(:apm_retention_filters)
        return nil if ids.empty?

        adoptable = ids.count do |id|
          Normalize.apm_retention_filter_adoptable?(capture.read(:apm_retention_filters, id))
        end
        { captured: ids.size, emitted: adoptable,
          skipped_unsupported_filter_type: ids.size - adoptable }
      end

      # A powerpack has no emittable body until `reconcile` records the
      # provider's own post-import state, so an unreconciled one is skipped.
      def powerpack_split(capture)
        ids = capture.ids(:powerpacks)
        return nil if ids.empty?

        reconciled = ids.count { |id| capture.normalized?(:powerpacks, id) }
        { captured: ids.size, emitted: reconciled,
          skipped_awaiting_reconcile: ids.size - reconciled }
      end
    end
  end
end
