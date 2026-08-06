# frozen_string_literal: true

require 'json'

module Pangea
  module Datadog
    module Absorb
      # What the estate holds that absorb does not absorb.
      #
      # The question this answers is NOT "how many resource types does the
      # provider declare". Provider 4.10.0 declares 136 and absorb emits 14, and
      # reading that as a 10% coverage figure is wrong in the way that matters:
      # a type with no objects in the account is not a gap, it is an absence.
      # Measured on this estate, 11 of the untouched types this census can reach
      # hold ZERO objects. The real gap is two.
      #
      # READ-ONLY, AND COUNTS ONLY. Every probe is a GET and nothing is written
      # to disk -- not a capture, a census. That matters because some of these
      # endpoints (users, api keys) return records this project has deliberately
      # not persisted pending a PII decision, and a census must not be the thing
      # that quietly starts persisting them.
      #
      # FIVE OUTCOMES, and the last two are the ones a naive version loses:
      #
      #   covered      absorb emits this type
      #   empty        reachable, zero objects -- an absence, not a gap
      #   gap          reachable, holds objects, absorb ignores them
      #   unreachable  403/404/405 -- the census COULD NOT ANSWER
      #   unprobed     declared by the provider, never looked at by this census
      #
      # `unreachable` must never be folded into `empty`. This account's app key
      # lacks scopes for security monitoring, workflows, datasets and org
      # groups; every one of those answers 403. Counting them as zero would
      # report full coverage of a surface nobody has actually looked at, which
      # is the exact failure this project keeps finding elsewhere.
      module Census
        Error = Class.new(StandardError)

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

        # How to count a captured kind LIVE, so the capture can be checked
        # against the estate it claims to mirror.
        #
        # THIS IS THE PRECONDITION FOR EVERY DANGLING FINDING the audit makes.
        # "widget references monitor 106953745, which is not in the estate" is
        # a defect if the capture holds every monitor, and a false alarm if it
        # does not. Nothing checked that until now -- the audit guards only on
        # a kind being entirely absent, which a partial capture passes.
        #
        # EVERY kind the capture can hold appears here. It first covered 9 of
        # 13, so a census that found nothing wrong reported no INCOMPLETE while
        # saying nothing at all about roles, both logs kinds and the APM
        # filters -- a third of the capture unchecked and indistinguishable
        # from verified. A spec pins that this stays exhaustive.
        #
        # EACH PATH MIRRORS THE ONE CAPTURE ITSELF CALLS, and that is not
        # decoration. Downtimes were checked against /api/v2/downtime while
        # capture reads /api/v1/downtime: the counts agreed at 18, so the check
        # passed, but the two endpoints return DIFFERENT ID NAMESPACES --
        # numeric in v1, UUID in v2. Comparing ids across that boundary reports
        # all 18 as missing and all 18 as extra. The count check was comparing
        # apples to oranges and getting away with it.
        #
        # kind => [path, collection key, id field]
        COMPLETENESS = {
          monitors: ['/api/v1/monitor?page_size=1000', nil, 'id'],
          dashboards: ['/api/v1/dashboard', 'dashboards', 'id'],
          slos: ['/api/v1/slo?limit=1000', 'data', 'id'],
          downtimes: ['/api/v1/downtime', nil, 'id'],
          teams: ['/api/v2/team?page%5Bsize%5D=1000', 'data', 'id'],
          powerpacks: ['/api/v2/powerpacks?page%5Blimit%5D=1000', 'data', 'id'],
          rum_applications: ['/api/v2/rum/applications', 'data', 'id'],
          dashboard_lists: ['/api/v1/dashboard/lists/manual', 'dashboard_lists', 'id'],
          logs_metrics: ['/api/v2/logs/config/metrics', 'data', 'id'],
          logs_pipelines: ['/api/v1/logs/config/pipelines', nil, 'id'],
          logs_indexes: ['/api/v1/logs/config/indexes', 'indexes', 'name'],
          apm_retention_filters: ['/api/v2/apm/config/retention-filters', 'data', 'id'],
          # page[size]=1000 is a 400 here: roles caps at 100, unlike the other
          # v2 collections. A page parameter that works everywhere else is not
          # a page parameter that works.
          roles: ['/api/v2/roles?page%5Bsize%5D=100', 'data', 'id']
        }.freeze

        # WHY EACH UNPROBED TYPE IS UNPROBED. A bare "UNPROBED 103" is a number,
        # not an answer: it cannot tell a type nobody considered from one that
        # was considered and ruled out. Ordered, first match wins, and a type
        # matching none of them is reported as UNCLASSIFIED so a new provider
        # resource cannot slip in unremarked.
        UNPROBED_REASONS = [
          # _ruleset and _rulesets, deliberately NOT _rule: a bare `_rule` is a
          # security rule, and a greedy pattern here silently re-filed 13 of
          # them as ordering config because this entry is matched first.
          [/_order$|_rules$|_rulesets?$|_concurrency_cap$/,
           'ordering or account-level setting, not a collection of objects'],
          [/_json$|_v2$|\Adatadog_dashboard\z|\Adatadog_downtime_schedule\z/,
           'alternate representation of a type absorb already emits'],
          [/\Adatadog_team_|\Adatadog_user_role\z|\Adatadog_service_account/,
           'sub-resource of a captured kind; adopt the parent first'],
          [/\Adatadog_org|\Adatadog_child_org|_allowlist\z|\Adatadog_organization/,
           'org-level singleton, not per-object config'],
          [/\Adatadog_(api_key|application_key|app_key)/,
           'credential material, deliberately never captured'],
          # MEASURED, and the two halves need opposite responses. Datadog
          # returns two different 403 bodies: the RBAC layer says "Failed
          # permission authorization checks", the product layer returns a bare
          # Forbidden. Cross-referencing the key's own 233 scopes against each
          # 403 splits them, and treating both as "widen the key" would have
          # been wrong for half.
          [/\Adatadog_security_monitoring/,
           'Cloud SIEM is not enabled for this org: the key already holds ' \
           'security_monitoring_rules_read and the role grants it, yet the route 403s ' \
           'and the signals route 404s. Widening the key changes nothing'],
          [/\Adatadog_sensitive_data_scanner/,
           'scope-blocked, fixable: needs data_scanner_read, which the owning role does not ' \
           'grant today. The permission exists and is unrestricted'],
          [/\Adatadog_(appsec|csm_threats|cloud_workload_security|cloud_configuration|compliance|security_notification)/,
           'security/compliance surface not measured; CSM posture findings ARE readable with ' \
           'this key and hold zero, so the product family is partly enabled and partly absent'],
          [/\Adatadog_(aws_cur_config|azure_uc_config|gcp_uc_config|cost_budget|custom_allocation)/,
           'cloud-cost management, a separate domain from observability config'],
          [/\Adatadog_synthetics/,
           'synthetics: the account holds zero tests, so the domain is empty'],
          [/\Adatadog_integration_/,
           'per-account integration; adopting these moves cloud credentials into code'],
          [/\Adatadog_on_call_/,
           'on-call scheduling: the account holds zero schedules'],
          [/\Adatadog_(incident|notebook|webhook|action_connection|app_builder|datastore|deployment_gate|observability_pipeline|openapi_api|restriction_policy|rum_retention|secure_embed|service_definition|slo_correction|software_catalog|agentless_scanning|cloud_inventory_sync|metric_metadata|monitor_notification_rule|authn_mapping|dataset|reference_table)/,
           'reachable but empty, or a product this account does not use']
        ].freeze

        # Live objects that NO provider resource can manage. Terraform is not
        # the tool for these, so they are not a gap absorb could ever close --
        # but they are estate surface, and leaving them out of the report would
        # overstate how much of the account is expressible as code.
        UNMANAGEABLE = {
          'notebooks' => ['/api/v1/notebooks', 'data']
        }.freeze

        Finding = Struct.new(:type, :count, :code, :suspect, :missing, :extra, keyword_init: true)

        # Datadog's v2 collections paginate, and the DEFAULT PAGE IS SMALL --
        # /api/v2/users returns 10 while the account holds 80. The first version
        # of this census counted the array it got back, so it reported 10 users
        # and was wrong by a factor of eight. It did not look wrong: 10 is a
        # perfectly plausible number of users.
        #
        # `meta.page.total_count` is the collection size and is what a count
        # means, so it wins whenever it is present.
        #
        # When it is ABSENT the array size is all there is, and a size that is
        # exactly a common page size is the shape of a silent truncation. That
        # cannot be resolved from one response, so it is reported as suspect
        # rather than asserted -- the same rule as everything else here: say
        # what is known, and say when something is not.
        COMMON_PAGE_SIZES = [10, 20, 25, 50, 100, 200, 500, 1000].freeze

        Result = Struct.new(:gaps, :empty, :unreachable, :unmanageable, :covered,
                            :unprobed, :stale_probes, :incomplete, keyword_init: true) do
          def ok? = gaps.empty?

          # nil means no provider schema was supplied, so the census does not
          # know its own denominator and must not imply one.
          def denominator_known? = !unprobed.nil?

          def findings
            {
              'covered' => covered,
              'unprobed' => unprobed&.size,
              'staleProbes' => stale_probes || [],
              'incomplete' => incomplete&.size,
              'incompleteDetail' => (incomplete || []).map do |f|
                { 'kind' => f.type, 'captured' => f.count, 'live' => f.code,
                  'onlyInEstate' => f.missing, 'onlyInCapture' => f.extra }
              end,
              'gaps' => gaps.size,
              'empty' => empty.size,
              'unreachable' => unreachable.size,
              'gapDetail' => gaps.map do |f|
                { 'type' => f.type, 'count' => f.count, 'countMaybeTruncated' => !f.suspect.nil? && f.suspect }
              end,
              'unreachableDetail' => unreachable.map { |f| { 'type' => f.type, 'code' => f.code } },
              'unmanageableDetail' => unmanageable.map { |f| { 'type' => f.type, 'count' => f.count } }
            }
          end

          def classify_unprobed(types)
            grouped = Hash.new { |h, k| h[k] = [] }
            types.each do |type|
              match = UNPROBED_REASONS.find { |pattern, _| pattern.match?(type) }
              key = match ? match[1] : 'UNCLASSIFIED -- decide whether this belongs in scope'
              grouped[key] << type
            end
            grouped.sort_by { |reason, list| [reason.start_with?('UNCLASSIFIED') ? 0 : 1, -list.size] }
          end

          def to_s
            lines = ["census: #{covered} types emitted, #{gaps.size} gaps, " \
                     "#{empty.size} reachable-and-empty, #{unreachable.size} unreachable"]
            if denominator_known?
              lines << "  UNPROBED #{unprobed.size} provider types this census does not look at:"
              classify_unprobed(unprobed).each do |reason, types|
                lines << format('    %3d  %s', types.size, reason)
              end
            else
              lines << '  UNPROBED unknown -- no provider schema given, so this census cannot ' \
                       'say what it does not look at. Pass --provider-schema.'
            end
            Array(incomplete).each do |f|
              lines << "  INCOMPLETE #{f.type}: captured #{f.count}, live #{f.code} " \
                       "(#{f.missing} only in the estate, #{f.extra} only in the capture) -- " \
                       'every dangling finding over this kind is unsafe until it matches'
            end
            Array(stale_probes).each do |type|
              lines << "  STALE PROBE #{type} is not declared by this provider -- the probe is dead"
            end
            gaps.each do |f|
              line = "  GAP #{f.type} holds #{f.count}, absorb ignores it"
              line += ' -- and that count is exactly a page size, so it may be truncated' if f.suspect
              lines << line
            end
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

        # `declared` is every resource type the PROVIDER declares, read from its
        # own schema. Without it this census has no denominator: it can say what
        # it looked at and found, and nothing at all about what it never looked
        # at. PROBES is a list of things someone thought of, and a report keyed
        # on what you remembered cannot describe what you forgot -- the same
        # defect verify's coverage check had when it walked its own table
        # instead of the capture directory.
        #
        # Measured here: the provider declares 136 types, absorb emits 14, this
        # census probes 19. That leaves 103 the census is silent about, and
        # silence is not coverage.
        def run(client:, covered:, declared: nil, capture: nil)
          gaps = []
          empty = []
          unreachable = []

          PROBES.each do |type, (path, key)|
            code, items, suspect = probe(client, path, key)
            next unreachable << Finding.new(type: type, code: code) unless code == 200

            if items.zero?
              empty << Finding.new(type: type, count: 0)
            else
              gaps << Finding.new(type: type, count: items, suspect: suspect)
            end
          end

          Result.new(gaps: gaps.sort_by(&:type), empty: empty.sort_by(&:type),
                     unreachable: unreachable.sort_by(&:type),
                     unmanageable: unmanageable_findings(client), covered: covered,
                     unprobed: unprobed_types(declared), stale_probes: stale_probes(declared),
                     incomplete: completeness(client, capture))
        end

        # nil when no capture was given: unasked, not answered.
        # COMPARES ID SETS, not counts. Counts coincide the moment one object
        # is deleted and another created -- an everyday week in a live estate --
        # and a capture that stale would pass while every dangling finding drawn
        # from it was quietly wrong about which objects exist.
        def completeness(client, capture)
          return nil if capture.nil?

          COMPLETENESS.filter_map do |kind, (path, key, id_field)|
            live = live_ids(client, path, key, id_field)
            next if live.nil?

            held = begin
              capture.ids(kind).map(&:to_s).to_set
            rescue Errno::ENOENT
              Set.new
            end
            next if held == live

            Finding.new(type: kind.to_s, count: held.size, code: live.size,
                        missing: (live - held).size, extra: (held - live).size)
          end
        end

        def live_ids(client, path, key, id_field)
          code, body = client.probe(path)
          return nil unless code == 200

          parsed = begin
            JSON.parse(body)
          rescue JSON::ParserError
            nil
          end
          items = key ? (parsed.is_a?(Hash) ? parsed[key] : nil) : parsed
          return nil unless items.is_a?(Array)

          items.map { |item| item[id_field].to_s }.to_set
        end

        def unprobed_types(declared)
          return nil if declared.nil?

          (declared - Emit::ADDRESS_SHARDS.keys - PROBES.keys).sort
        end

        # A probe for a type the provider does not declare is dead: either a
        # typo, or a resource the provider removed. Either way it will answer
        # forever without measuring anything.
        def stale_probes(declared)
          return [] if declared.nil?

          (PROBES.keys - declared).sort
        end

        # The provider's own schema, as `terraform providers schema -json`
        # writes it.
        def declared_types(schema_path)
          schemas = JSON.parse(File.read(schema_path))['provider_schemas']
          raise Error, "#{schema_path} holds no provider_schemas" unless schemas.is_a?(Hash)

          schemas.values.flat_map { |s| (s['resource_schemas'] || {}).keys }.uniq.sort
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
          return [code, 0, false] unless code == 200

          parsed = begin
            JSON.parse(body)
          rescue JSON::ParserError
            nil
          end
          items = key ? (parsed.is_a?(Hash) ? parsed[key] : nil) : parsed
          returned = items.is_a?(Array) ? items.size : 0
          total = parsed.is_a?(Hash) ? parsed.dig('meta', 'page', 'total_count') : nil

          return [code, total, false] if total.is_a?(Integer)

          [code, returned, COMMON_PAGE_SIZES.include?(returned)]
        end
      end
    end
  end
end
