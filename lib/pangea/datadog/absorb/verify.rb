# frozen_string_literal: true

require 'json'
require_relative 'normalize'
require_relative 'classify'

module Pangea
  module Datadog
    module Absorb
      # The state-match proof.
      #
      # Absorb is only worth anything if the code it produces provably says the
      # same thing as the live estate. Verify loads the emitted Ruby, evaluates
      # it against a recording synthesizer, and diffs every resource's attributes
      # against the same projection taken from the capture. A non-empty diff is a
      # failure, not a warning.
      #
      # This runs without the provider stack on purpose. It answers "is the code
      # a faithful representation of the estate", which is a property of the code
      # and the capture alone. Whether Datadog then accepts an apply is a
      # separate question answered by a plan, and a plan is worthless if this
      # step has not already passed.
      class Verify
        # Three outcomes, deliberately not merged.
        #
        #   diffs        the emitted attributes disagree with the estate. A bug
        #                in the emitter or the projection. Fails.
        #   unmapped     a live field nothing here knows about. Could be new
        #                Datadog surface or an oversight; either way the code is
        #                not proven faithful. Fails.
        #   unmanageable a live field the Terraform provider does not model, so
        #                no IaC can own it. Adoption leaves it untouched. Does
        #                not fail, but is always reported -- "state match" must
        #                never be read as "fully managed".
        Result = Struct.new(:checked, :matched, :diffs, :unmapped, :unmanageable, keyword_init: true) do
          def ok?
            diffs.empty? && unmapped.empty?
          end

          # The machine-readable half of the same answer to_s renders. Kept
          # here so the receipt can never disagree with the printed summary.
          def findings
            {
              'checked' => checked,
              'matched' => matched,
              'diffs' => diffs.size,
              'unmapped' => unmapped.size,
              'unmanageable' => unmanageable.size,
              'diffAddresses' => diffs.map { |d| "#{d[:address]}##{d[:attribute]}" }.sort.first(50),
              'unmappedAddresses' => unmapped.map { |u| u[:address] }.sort.first(50),
              'unmanageableByKeys' => unmanageable.group_by { |u| u[:keys] }
                                                  .map { |keys, es| { 'keys' => keys, 'count' => es.size } }
            }
          end

          def to_s
            lines = ["checked #{checked}, matched #{matched}, diffs #{diffs.size}, " \
                     "unmapped #{unmapped.size}, unmanageable #{unmanageable.size}"]
            diffs.each { |d| lines << "  DIFF #{d[:address]} #{d[:attribute]}" }
            unmapped.each { |u| lines << "  UNMAPPED #{u[:address]} #{u[:keys].inspect}" }
            unmanageable.group_by { |g| g[:keys] }.each do |keys, entries|
              lines << "  UNMANAGEABLE #{keys.inspect} on #{entries.size} resources " \
                       '(left as-is in Datadog; no provider support)'
            end
            lines.join("\n")
          end
        end

        # Stands in for the Pangea synthesizer. It records rather than
        # synthesizes, so the emitted file is genuinely executed -- a file that
        # does not parse or that calls an unknown resource fails here.
        class RecordingSynth
          attr_reader :recorded

          def initialize
            @recorded = {}
          end

          def datadog_monitor(name, attrs)
            record(:datadog_monitor, name, attrs)
          end

          def datadog_dashboard(name, attrs)
            record(:datadog_dashboard, name, attrs)
          end

          def respond_to_missing?(method, include_private = false)
            method.to_s.start_with?('datadog_') || super
          end

          def method_missing(method, *args)
            return super unless method.to_s.start_with?('datadog_')

            record(method, args[0], args[1] || {})
          end

          def extend(*)
            self
          end

          private

          def record(kind, name, attrs)
            address = "#{kind}.#{name}"
            raise "duplicate resource address #{address}" if @recorded.key?(address)

            @recorded[address] = attrs
            address
          end
        end

        attr_reader :capture, :out_dir

        def initialize(capture:, out_dir:)
          @capture = capture
          @out_dir = out_dir
        end

        def run
          recorded = load_emitted
          imports  = read_imports
          diffs    = []
          unmapped = []
          unmanage = []
          matched  = 0

          recorded.each do |address, actual|
            id = imports[address]
            if id.nil?
              diffs << { address: address, attribute: '(no import mapping)' }
              next
            end

            kind     = address.split('.', 2).first
            payload  = load_payload(kind, id)
            expected =
              case kind
              when 'datadog_monitor' then Normalize.monitor(payload)
              when 'datadog_dashboard_json'
                Normalize.dashboard_json_for(payload, capture.normalized(:dashboards, id))
              when 'datadog_service_level_objective' then Normalize.slo(payload)
              when 'datadog_downtime' then Normalize.downtime(payload)
              when 'datadog_logs_custom_pipeline' then Normalize.logs_custom_pipeline(payload)
              when 'datadog_logs_integration_pipeline' then Normalize.logs_integration_pipeline(payload)
              when 'datadog_logs_metric' then Normalize.logs_metric(payload)
              when 'datadog_logs_index' then Normalize.logs_index(payload)
              when 'datadog_team' then Normalize.team(payload)
              when 'datadog_role' then Normalize.role(payload)
              when 'datadog_rum_application' then Normalize.rum_application(payload)
              when 'datadog_apm_retention_filter' then Normalize.apm_retention_filter(payload)
              when 'datadog_dashboard_list' then Normalize.dashboard_list(payload)
              when 'datadog_powerpack'
                Normalize.powerpack(payload, capture.normalized(:powerpacks, id))
              else Normalize.dashboard(payload)
              end

            leftover, unmanaged = unmapped_keys(kind, payload)
            unmapped << { address: address, keys: leftover } unless leftover.empty?
            unmanage << { address: address, keys: unmanaged } unless unmanaged.empty?

            compare = Normalize.canonicalize(actual.reject { |k, _| k == :lifecycle })
            found = attribute_diffs(address, expected, compare)
            diffs.concat(found)
            matched += 1 if found.empty?
          end

          # Every emitted resource must be reachable from a built module. A file
          # whose module was shadowed would otherwise pass by never being checked.
          imports.each_key do |address|
            next if recorded.key?(address)

            diffs << { address: address, attribute: '(emitted but never built)' }
          end

          Result.new(checked: recorded.size, matched: matched, diffs: diffs,
                     unmapped: unmapped, unmanageable: unmanage)
        end

        # Every emitted file is loaded and built. Anonymous module namespacing
        # keeps repeated runs in one process from colliding.
        def load_emitted
          # Clear the namespace first. Modules from a PREVIOUS verify stay
          # defined in the process, and each_built_module enumerates the whole
          # namespace -- so verifying a second directory would silently count the
          # first one's resources too. Harmless in a one-shot CLI run, wrong in a
          # long-lived process, and it showed up first as a spec that counted 2
          # resources in a capture holding 1.
          ::Pangea.send(:remove_const, :Absorbed) if ::Pangea.const_defined?(:Absorbed, false)

          synth = RecordingSynth.new
          Dir.glob(File.join(out_dir, '**', '*.rb')).sort.each { |file| load(file) }
          each_built_module { |mod| mod.build(synth) }
          synth.recorded
        end

        def each_built_module
          return unless defined?(::Pangea::Absorbed)

          ::Pangea::Absorbed.constants.sort.each do |const|
            mod = ::Pangea::Absorbed.const_get(const)
            yield(mod) if mod.respond_to?(:build)
          end
        end

        def read_imports
          path = File.join(out_dir, 'imports.json')
          File.exist?(path) ? JSON.parse(File.read(path)) : {}
        end

        KIND_TO_CAPTURE = {
          'datadog_monitor' => :monitors,
          'datadog_service_level_objective' => :slos,
          'datadog_downtime' => :downtimes,
          'datadog_logs_custom_pipeline' => :logs_pipelines,
          'datadog_logs_integration_pipeline' => :logs_pipelines,
          'datadog_logs_metric' => :logs_metrics,
          'datadog_logs_index' => :logs_indexes,
          'datadog_team' => :teams,
          'datadog_role' => :roles,
          'datadog_rum_application' => :rum_applications,
          'datadog_apm_retention_filter' => :apm_retention_filters,
          'datadog_dashboard_list' => :dashboard_lists,
          'datadog_powerpack' => :powerpacks
        }.freeze

        def load_payload(kind, id)
          capture.read(KIND_TO_CAPTURE.fetch(kind, :dashboards), id)
        end

        MONITOR_LIFECYCLE = { lifecycle: { ignore_changes: [:new_host_delay] } }.freeze

        # Returns [oversights, provider-unmanageable fields].
        def unmapped_keys(kind, payload)
          case kind
          when 'datadog_monitor'
            u = Normalize.monitor_unmapped(payload)
            [u[:fields] + u[:options].map { |o| "options.#{o}" },
             u[:unmanageable].map { |o| "options.#{o}" }]
          when 'datadog_dashboard_json'
            # The body is carried verbatim, so nothing can be silently lost.
            [[], Normalize.dashboard_json_unmanageable(payload)]
          when 'datadog_service_level_objective'
            u = Normalize.slo_unmapped(payload)
            [u[:fields], u[:unmanageable]]
          when 'datadog_downtime'
            u = Normalize.downtime_unmapped(payload)
            [u[:fields], u[:unmanageable]]
          when 'datadog_logs_custom_pipeline', 'datadog_logs_integration_pipeline',
               'datadog_logs_metric', 'datadog_logs_index'
            u = Normalize.logs_unmapped(kind, payload)
            [u[:fields], u[:unmanageable]]
          when 'datadog_powerpack'
            # The body IS the provider's own read, so nothing can be silently
            # lost between the two -- the same argument as datadog_dashboard_json.
            [[], []]
          when 'datadog_team', 'datadog_role', 'datadog_rum_application',
               'datadog_apm_retention_filter', 'datadog_dashboard_list'
            u = Normalize.account_unmapped(kind, payload)
            [u[:fields], u[:unmanageable]]
          else
            [Normalize.dashboard_unmapped(payload), []]
          end
        end

        # Reports the attribute that differs rather than dumping both sides.
        # A 97-widget dashboard produces an unreadable diff otherwise; the
        # attribute name plus the capture file is enough to investigate.
        def attribute_diffs(address, expected, actual)
          (expected.keys | actual.keys).sort.filter_map do |key|
            next if expected[key] == actual[key]

            { address: address, attribute: key.to_s }
          end
        end
      end
    end
  end
end
