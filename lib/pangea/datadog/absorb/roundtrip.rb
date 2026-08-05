# frozen_string_literal: true

require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'
require_relative 'normalize'
require_relative 'emit'
require_relative 'classify'
require_relative 'rules'

module Pangea
  module Datadog
    module Absorb
      # Closes the gap `verify` cannot reach.
      #
      # `verify` proves CODE == ESTATE at the attribute level. It does NOT prove
      # that terraform, holding the real provider schema, would plan to "No
      # changes" against the live object. Those are different claims, and the
      # second is the one adoption actually depends on: a body can match the API
      # perfectly and still diff forever because the provider computes a field,
      # renames it, models it as a block, or declares it conflicting.
      #
      # Every such defect found in this project was invisible to attribute-level
      # matching and visible only to a real plan:
      #
      #   new_host_delay          deprecated AND defaulted to 300 by the provider
      #   widget/definition       provider wants per-type blocks, not the API shape
      #   is_read_only            dropped by the provider's own normalization
      #   target_display          computed inside a thresholds block
      #   sli_specification       a nested hash in the API, blocks in the provider
      #   monitor_tags ["*"]      the "no filter" sentinel, and mutually
      #                           exclusive with monitor_id
      #
      # READ-ONLY BY CONSTRUCTION. `terraform import` and `terraform plan` are
      # both GET against Datadog; import writes LOCAL state only. This never
      # applies, and there is deliberately no code path here that could.
      class Roundtrip
        Error = Class.new(StandardError)

        KINDS = {
          monitors: { resource: 'datadog_monitor', capture: :monitors },
          dashboards: { resource: 'datadog_dashboard_json', capture: :dashboards },
          slos: { resource: 'datadog_service_level_objective', capture: :slos },
          downtimes: { resource: 'datadog_downtime', capture: :downtimes },
          # One endpoint, two resources: `is_read_only` decides which. They are
          # separate kinds here so the pass rate is reported per resource --
          # a custom pipeline carries a full processor chain and an integration
          # pipeline carries one boolean, and averaging them hides the hard one.
          logs_custom_pipelines: { resource: 'datadog_logs_custom_pipeline', capture: :logs_pipelines },
          logs_integration_pipelines: { resource: 'datadog_logs_integration_pipeline',
                                        capture: :logs_pipelines },
          logs_metrics: { resource: 'datadog_logs_metric', capture: :logs_metrics },
          logs_indexes: { resource: 'datadog_logs_index', capture: :logs_indexes },
          teams: { resource: 'datadog_team', capture: :teams },
          roles: { resource: 'datadog_role', capture: :roles },
          rum_applications: { resource: 'datadog_rum_application', capture: :rum_applications },
          apm_retention_filters: { resource: 'datadog_apm_retention_filter',
                                   capture: :apm_retention_filters },
          dashboard_lists: { resource: 'datadog_dashboard_list', capture: :dashboard_lists },
          powerpacks: { resource: 'datadog_powerpack', capture: :powerpacks }
        }.freeze

        # How to turn a kind's post-import state into a reusable body, and the
        # minimal config `import` needs to run at all. Dashboards hide their
        # whole body in one JSON string; a powerpack's is the pruned state.
        RECONCILABLE = {
          dashboards: {
            seed: -> { { 'dashboard' => '{}' } },
            extract: ->(attrs) { attrs['dashboard'].nil? ? nil : JSON.parse(attrs['dashboard']) },
            fidelity_kind: 'datadog_dashboard_json'
          },
          powerpacks: {
            seed: -> { { 'name' => 'probe' } },
            extract: ->(attrs) { Normalize.prune_provider_state(attrs) },
            fidelity_kind: 'datadog_powerpack',
            # A powerpack has no body at all until one is recorded, so the
            # "is it already clean?" pre-check cannot run on the first pass --
            # it would need the very thing this is about to produce.
            sidecar_only: true
          }
        }.freeze

        Outcome = Struct.new(:kind, :id, :name, :status, :detail, keyword_init: true) do
          def clean? = status == :no_changes
        end

        attr_reader :capture, :provider_dir, :terraform, :site

        attr_reader :rules

        def initialize(capture:, provider_dir:, terraform: 'terraform',
                       site: 'datadoghq.com', rules: Rules.none)
          @capture      = capture
          @provider_dir = provider_dir
          @terraform    = terraform
          @site         = site
          @rules        = rules
        end

        # Sample `per_kind` objects of each kind and plan each one.
        def run(kinds: KINDS.keys, per_kind: 1, credentials:)
          kinds.flat_map do |kind|
            spec = KINDS.fetch(kind) { raise Error, "unknown kind #{kind}" }
            adoptable(kind, spec).first(per_kind).map do |id|
              plan_one(kind, spec, id, credentials)
            end
          end
        end

        # Only objects the emitter would actually DECLARE. Testing the whole
        # capture was wrong: it planned the 64 monitors another IaC system owns
        # and the retire-tier dashboards, none of which we ever emit, so the
        # rate answered a question nobody asked.
        def adoptable(kind, spec)
          ids = capture.ids(spec[:capture])
          case kind
          when :monitors
            ids.select { |id| rules.adopt?(capture.read(:monitors, id)) }
          when :roles
            ids.reject { |id| Normalize.role_managed?(capture.read(:roles, id)) }
          when :apm_retention_filters
            ids.select do |id|
              Normalize.apm_retention_filter_adoptable?(capture.read(:apm_retention_filters, id))
            end
          when :logs_custom_pipelines
            ids.reject { |id| Normalize.logs_pipeline_read_only?(capture.read(:logs_pipelines, id)) }
          when :logs_integration_pipelines
            ids.select { |id| Normalize.logs_pipeline_read_only?(capture.read(:logs_pipelines, id)) }
          when :dashboards
            twins = rules.dedupe_identical? ? Classify.twin_index(capture) : {}
            ids.reject do |id|
              Classify.dashboard_tier(capture.read(:dashboards, id),
                                      id: id, rules: rules, twins: twins) == Classify::TIER_RETIRE
            end
          else ids
          end
        end

        def plan_one(kind, spec, id, credentials)
          payload = capture.read(spec[:capture], id)
          name    = payload['name'] || payload['title'] || id

          Dir.mktmpdir("absorb-roundtrip-#{kind}-") do |dir|
            write_workspace(dir, spec[:resource], body_for(kind, payload, id))
            env = terraform_env(dir, credentials)

            run_tf(dir, env, 'init', '-no-color', '-input=false')
            imported = run_tf(dir, env, 'import', '-no-color', '-input=false',
                              "#{spec[:resource]}.probe", id.to_s)
            unless imported[:ok]
              return Outcome.new(kind: kind, id: id, name: name, status: :import_failed,
                                 detail: tail(imported[:err]))
            end

            planned = run_tf(dir, env, 'plan', '-no-color', '-input=false', '-lock=false')
            classify_plan(kind, id, name, planned)
          end
        end

        # Record the provider's OWN post-import body for each dashboard that
        # does not already plan clean. Read-only against Datadog: import is a
        # GET that writes local state, and nothing is applied.
        #
        # Only touches dashboards, and only the ones that need it, so the
        # capture keeps the raw API payload as the source of truth everywhere a
        # transformation of it is sufficient.
        def reconcile(credentials:, only_failing: true, kinds: [:dashboards])
          kinds.flat_map { |kind| reconcile_kind(kind, credentials, only_failing) }
        end

        def reconcile_kind(kind, credentials, only_failing)
          spec = KINDS.fetch(kind) { raise Error, "unknown kind #{kind}" }
          recipe = RECONCILABLE.fetch(kind) { raise Error, "#{kind} has no reconcile recipe" }
          twins = rules.dedupe_identical? ? Classify.twin_index(capture) : {}

          adoptable(kind, spec).map do |id|
            # An archetype-tier dashboard is emitted by an engine, not from a
            # body, so a recorded body would sit unread. Say so rather than
            # write a file nothing consumes.
            if kind == :dashboards
              tier = Classify.dashboard_tier(capture.read(:dashboards, id),
                                             id: id, rules: rules, twins: twins)
              next { kind: kind, id: id, status: :archetype } if tier == Classify::TIER_ARCHETYPE
            end

            # A sidecar that no longer describes the captured object is the one
            # case where the plan pre-check must NOT be trusted: it would plan
            # the stale body against the live object, and a stale body can still
            # plan clean if the live object drifted back. Detection lives in
            # verify; this is the repair.
            sidecar = capture.normalized(spec[:capture], id)
            stale = !Normalize.sidecar_fidelity(recipe[:fidelity_kind],
                                                capture.read(spec[:capture], id), sidecar).empty?

            skip_precheck = stale || (recipe[:sidecar_only] && sidecar.nil?)
            if only_failing && !skip_precheck && plan_one(kind, spec, id, credentials).clean?
              next { kind: kind, id: id, status: :already_clean }
            end

            body = provider_body(spec[:resource], id, credentials, recipe)
            next { kind: kind, id: id, status: :unavailable } if body.nil?

            capture.write_normalized(spec[:capture], id, body)
            { kind: kind, id: id, status: stale ? :refreshed : :recorded }
          end.compact
        end

        # Import into a throwaway workspace and read back what the provider
        # itself stored. That body is authoritative by construction: `prepResource`
        # is deterministic and runs on both sides, so a config that IS the
        # provider's read necessarily plans clean.
        def provider_body(resource, id, credentials, recipe)
          Dir.mktmpdir('absorb-reconcile-') do |dir|
            write_workspace(dir, resource, recipe[:seed].call)
            env = terraform_env(dir, credentials)
            run_tf(dir, env, 'init', '-no-color', '-input=false')
            imported = run_tf(dir, env, 'import', '-no-color', '-input=false',
                              "#{resource}.probe", id.to_s)
            return nil unless imported[:ok]

            state = JSON.parse(File.read(File.join(dir, 'terraform.tfstate')))
            attrs = state.dig('resources', 0, 'instances', 0, 'attributes')
            attrs.nil? ? nil : recipe[:extract].call(attrs)
          end
        rescue StandardError
          nil
        end

        def classify_plan(kind, id, name, planned)
          out = "#{planned[:out]}#{planned[:err]}"
          status =
            if out.include?('No changes')      then :no_changes
            elsif !planned[:ok]                then :plan_error
            else :drift
            end
          Outcome.new(kind: kind, id: id, name: name, status: status,
                      detail: status == :no_changes ? nil : tail(out))
        end

        # The per-kind terraform body. This is the ONE place the proven recipe
        # lives, so a change to the emitter that breaks the plan shows up here
        # rather than in production.
        #
        # It must plan the body the EMITTER declares, not a second opinion about
        # it -- including the reconcile sidecar. Planning the raw projection
        # while emitting the recorded one would make the rate answer a question
        # about code nobody ships.
        def body_for(kind, payload, id = nil)
          case kind
          when :monitors
            attrs = stringify(Normalize.monitor(payload))
            attrs['lifecycle'] = [{ 'ignore_changes' => Emit::MONITOR_UNROUNDTRIPPABLE.map(&:to_s) }]
            attrs
          when :dashboards
            stringify(Normalize.dashboard_json_for(payload, id && capture.normalized(:dashboards, id)))
          when :slos then stringify(Normalize.slo(payload))
          when :downtimes then stringify(Normalize.downtime(payload))
          when :logs_custom_pipelines then stringify(Normalize.logs_custom_pipeline(payload))
          when :logs_integration_pipelines then stringify(Normalize.logs_integration_pipeline(payload))
          when :logs_metrics then stringify(Normalize.logs_metric(payload))
          when :logs_indexes then stringify(Normalize.logs_index(payload))
          when :teams then stringify(Normalize.team(payload))
          when :roles then stringify(Normalize.role(payload))
          when :rum_applications then stringify(Normalize.rum_application(payload))
          when :apm_retention_filters then stringify(Normalize.apm_retention_filter(payload))
          when :dashboard_lists then stringify(Normalize.dashboard_list(payload))
          when :powerpacks
            body = Normalize.powerpack(payload, capture.normalized(:powerpacks, id))
            raise Error, "powerpack #{id} has no reconciled body; run reconcile first" if body.nil?

            stringify(body)
          else raise Error, "no terraform body for #{kind}"
          end
        end

        def write_workspace(dir, resource, body)
          File.write(File.join(dir, 'main.tf.json'), JSON.pretty_generate(
            'terraform' => { 'required_providers' => {
              'datadog' => { 'source' => 'DataDog/datadog' }
            } },
            'provider' => { 'datadog' => {} },
            'resource' => { resource => { 'probe' => body } }
          ))
          # A filesystem mirror keeps the run offline and pinned to the provider
          # the operator actually ships, not whatever the registry serves today.
          File.write(File.join(dir, 'tfrc'), <<~HCL)
            provider_installation {
              filesystem_mirror {
                path    = "#{provider_dir}"
                include = ["registry.terraform.io/DataDog/datadog"]
              }
              direct { exclude = ["registry.terraform.io/DataDog/datadog"] }
            }
          HCL
        end

        def terraform_env(dir, credentials)
          {
            'TF_CLI_CONFIG_FILE' => File.join(dir, 'tfrc'),
            'DD_API_KEY' => credentials.fetch(:api_key),
            'DD_APP_KEY' => credentials.fetch(:app_key),
            'DD_SITE' => site,
            'TF_IN_AUTOMATION' => '1'
          }
        end

        def run_tf(dir, env, *args)
          out, err, status = Open3.capture3(env, terraform, *args, chdir: dir)
          { ok: status.success?, out: out, err: err }
        end

        def stringify(attrs)
          attrs.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
        end

        def tail(text)
          text.to_s.lines.reject { |l| l.strip.empty? }.last(6).join.strip
        end
      end
    end
  end
end
