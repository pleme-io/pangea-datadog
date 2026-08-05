# frozen_string_literal: true

require 'json'

module Pangea
  module Datadog
    module Absorb
      # What the estate holds that absorb does not absorb.
      #
      # The question this answers is NOT "how many resource types does the
      # provider declare". Provider 4.10.0 declares 136 and absorb touches 16,
      # and reading that as a 12% coverage figure is wrong in the way that
      # matters: a type with no objects in the account is not a gap, it is an
      # absence. Measured on this estate, 20 of the untouched types the census
      # can reach hold ZERO objects. The real gap was three.
      #
      # READ-ONLY, AND COUNTS ONLY. Every probe is a GET and nothing is written
      # to disk -- not a capture, a census. That matters because some of these
      # endpoints (users, api keys) return records this project has deliberately
      # not persisted pending a PII decision, and a census must not be the thing
      # that quietly starts persisting them.
      #
      # FOUR OUTCOMES, and the fourth is the one a naive version loses:
      #
      #   covered      absorb emits this type
      #   empty        reachable, zero objects -- an absence, not a gap
      #   gap          reachable, holds objects, absorb ignores them
      #   unreachable  403/404/405 -- the census COULD NOT ANSWER
      #
      # `unreachable` must never be folded into `empty`. This account's app key
      # lacks scopes for security monitoring, workflows, datasets and org
      # groups; every one of those answers 403. Counting them as zero would
      # report full coverage of a surface nobody has actually looked at, which
      # is the exact failure this project keeps finding elsewhere.
      module Census
        # resource type => [path, the key its collection lives under]
        # A nil key means the response body IS the collection.
        PROBES = {
          'datadog_synthetics_test' => ['/api/v1/synthetics/tests', 'tests'],
          'datadog_synthetics_global_variable' => ['/api/v1/synthetics/variables', 'variables'],
          'datadog_user' => ['/api/v2/users', 'data'],
          'datadog_logs_archive' => ['/api/v2/logs/config/archives', 'data'],
          'datadog_logs_restriction_query' => ['/api/v2/logs/config/restriction_queries', 'data'],
          'datadog_logs_custom_destination' => ['/api/v2/logs/config/custom-destinations', 'data'],
          'datadog_security_monitoring_rule' => ['/api/v2/security_monitoring/rules', 'data'],
          'datadog_security_monitoring_suppression' =>
            ['/api/v2/security_monitoring/configuration/suppressions', 'data'],
          'datadog_sensitive_data_scanner_group' => ['/api/v2/sensitive-data-scanner/config', 'data'],
          'datadog_spans_metric' => ['/api/v2/apm/config/metrics', 'data'],
          'datadog_rum_metric' => ['/api/v2/rum/config/metrics', 'data'],
          'datadog_monitor_config_policy' => ['/api/v2/monitor/policy', 'data'],
          'datadog_incident_type' => ['/api/v2/incidents/config/types', 'data'],
          'datadog_metric_tag_configuration' => ['/api/v2/metrics?filter[configured]=true', 'data'],
          'datadog_reference_table' => ['/api/v2/reference-tables/tables', 'data'],
          'datadog_on_call_schedule' => ['/api/v2/on-call/schedules', 'data'],
          'datadog_workflow_automation' => ['/api/v2/workflows', 'data'],
          'datadog_dataset' => ['/api/v2/datasets', 'data'],
          'datadog_org_group' => ['/api/v2/org_groups', 'data']
        }.freeze

        # Live objects that NO provider resource can manage. Terraform is not
        # the tool for these, so they are not a gap absorb could ever close --
        # but they are estate surface, and leaving them out of the report would
        # overstate how much of the account is expressible as code.
        UNMANAGEABLE = {
          'notebooks' => ['/api/v1/notebooks', 'data']
        }.freeze

        Finding = Struct.new(:type, :count, :code, keyword_init: true)

        Result = Struct.new(:gaps, :empty, :unreachable, :unmanageable, :covered, keyword_init: true) do
          def ok? = gaps.empty?

          def findings
            {
              'covered' => covered,
              'gaps' => gaps.size,
              'empty' => empty.size,
              'unreachable' => unreachable.size,
              'gapDetail' => gaps.map { |f| { 'type' => f.type, 'count' => f.count } },
              'unreachableDetail' => unreachable.map { |f| { 'type' => f.type, 'code' => f.code } },
              'unmanageableDetail' => unmanageable.map { |f| { 'type' => f.type, 'count' => f.count } }
            }
          end

          def to_s
            lines = ["census: #{covered} types emitted, #{gaps.size} gaps, " \
                     "#{empty.size} reachable-and-empty, #{unreachable.size} unreachable"]
            gaps.each { |f| lines << "  GAP #{f.type} holds #{f.count}, absorb ignores it" }
            unmanageable.each do |f|
              lines << "  UNMANAGEABLE #{f.type} holds #{f.count}, no provider resource exists"
            end
            unreachable.each do |f|
              lines << "  UNREACHABLE #{f.type} returned #{f.code} -- NOT the same as zero"
            end
            lines.join("\n")
          end
        end

        module_function

        def run(client:, covered:)
          gaps = []
          empty = []
          unreachable = []

          PROBES.each do |type, (path, key)|
            code, items = probe(client, path, key)
            next unreachable << Finding.new(type: type, code: code) unless code == 200

            if items.zero?
              empty << Finding.new(type: type, count: 0)
            else
              gaps << Finding.new(type: type, count: items)
            end
          end

          Result.new(gaps: gaps.sort_by(&:type), empty: empty.sort_by(&:type),
                     unreachable: unreachable.sort_by(&:type),
                     unmanageable: unmanageable_findings(client), covered: covered)
        end

        def unmanageable_findings(client)
          UNMANAGEABLE.filter_map do |type, (path, key)|
            code, items = probe(client, path, key)
            next unless code == 200 && items.positive?

            Finding.new(type: type, count: items)
          end
        end

        # A census asks a question; a non-200 is an ANSWER OF "I could not tell",
        # so it is returned rather than raised. get_json raises, which would
        # abort the whole census on the first endpoint the key cannot read.
        def probe(client, path, key)
          code, body = client.probe(path)
          return [code, 0] unless code == 200

          parsed = begin
            JSON.parse(body)
          rescue JSON::ParserError
            nil
          end
          items = key ? (parsed.is_a?(Hash) ? parsed[key] : nil) : parsed
          [code, items.is_a?(Array) ? items.size : 0]
        end
      end
    end
  end
end
