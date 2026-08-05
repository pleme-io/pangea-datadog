# frozen_string_literal: true

require 'json'

module Pangea
  module Datadog
    module Absorb
      # Projects a live Datadog API payload onto the attribute surface of the
      # corresponding typed Pangea resource.
      #
      # This is the load-bearing module. "State match" means: the attributes we
      # emit, re-synthesized, equal the attributes the live object projects to.
      # Both sides of that comparison come from here, so the projection is
      # declared once as data rather than written twice as code.
      #
      # Two shapes have to be reconciled:
      #
      #   API      monitor.options.{thresholds,notify_no_data,renotify_interval,...}
      #   Terraform  datadog_monitor.{monitor_thresholds,notify_no_data,...}
      #
      # The provider flattens `options` to the top level and renames two of its
      # members. Everything else is a straight lift.
      module Normalize
        module_function

        # options key => terraform attribute name.
        # Identical names are listed explicitly so the table is the whole truth
        # and no key is carried by an implicit fallthrough.
        MONITOR_OPTION_MAP = {
          'enable_logs_sample' => :enable_logs_sample,
          'enable_samples' => :enable_samples,
          'escalation_message' => :escalation_message,
          'evaluation_delay' => :evaluation_delay,
          'group_retention_duration' => :group_retention_duration,
          'groupby_simple_monitor' => :groupby_simple_monitor,
          'include_tags' => :include_tags,
          'new_group_delay' => :new_group_delay,
          'new_host_delay' => :new_host_delay,
          'no_data_timeframe' => :no_data_timeframe,
          'notification_preset_name' => :notification_preset_name,
          'notify_audit' => :notify_audit,
          'notify_by' => :notify_by,
          'notify_no_data' => :notify_no_data,
          'on_missing_data' => :on_missing_data,
          'renotify_interval' => :renotify_interval,
          'renotify_occurrences' => :renotify_occurrences,
          'renotify_statuses' => :renotify_statuses,
          'require_full_window' => :require_full_window,
          'scheduling_options' => :scheduling_options,
          'timeout_h' => :timeout_h,
          'variables' => :variables,
          # renamed by the provider
          'thresholds' => :monitor_thresholds,
          'threshold_windows' => :monitor_threshold_windows
        }.freeze

        # Present in the API response, owned by Datadog, never authored.
        # `silenced` is deliberately here: it is mute state, not configuration,
        # and the provider does not manage it.
        MONITOR_SERVER_FIELDS = %w[
          id created created_at creator deleted modified org_id
          overall_state overall_state_modified matching_downtimes multi
        ].freeze

        # Runtime state rather than configuration. Mute windows are set by
        # operators during incidents and are not authored.
        MONITOR_SERVER_OPTIONS = %w[silenced].freeze

        # Configuration Datadog stores that the Terraform provider does not
        # model, verified against DataDog/datadog 4.17.0 datadog_monitor.
        #
        # These are NOT defects in pangea-datadog, and not oversights in the
        # projection above. They are the honest boundary of what any Terraform
        # based IaC can own for a monitor. Adoption leaves them exactly as they
        # are in Datadog; the emitted code neither sets nor clears them. They
        # are reported so nobody reads "state match" as "fully managed".
        MONITOR_PROVIDER_UNSUPPORTED = {
          'locked' => 'deprecated by Datadog, superseded by restricted_roles',
          'restriction_query' => 'not present in the datadog_monitor provider schema'
        }.freeze

        DASHBOARD_FIELD_MAP = {
          'title' => :title,
          'layout_type' => :layout_type,
          'description' => :description,
          'is_read_only' => :is_read_only,
          'notify_list' => :notify_list,
          'reflow_type' => :reflow_type,
          'restricted_roles' => :restricted_roles,
          'tags' => :tags,
          'widgets' => :widget,
          'tabs' => :tab,
          'template_variables' => :template_variable,
          'template_variable_presets' => :template_variable_preset
        }.freeze

        DASHBOARD_SERVER_FIELDS = %w[
          id url author_handle author_name created_at modified_at deleted_at
        ].freeze

        # Widget ids are assigned by Datadog on write. Keeping them would make
        # every emitted dashboard carry values we cannot reproduce, so they are
        # dropped on both sides of the comparison and never authored.
        WIDGET_SERVER_FIELDS = %w[id].freeze

        # ---- monitors ----------------------------------------------------

        def monitor(payload)
          attrs = {}
          attrs[:name]    = payload['name']
          attrs[:type]    = payload['type']
          attrs[:query]   = payload['query']
          attrs[:message] = payload['message'].to_s

          attrs[:tags] = Array(payload['tags']) unless blank?(payload['tags'])
          attrs[:restricted_roles] = payload['restricted_roles'] unless blank?(payload['restricted_roles'])
          attrs[:draft_status] = payload['draft_status'] unless blank?(payload['draft_status'])

          # The provider models priority as a string; the API returns an integer.
          attrs[:priority] = payload['priority'].to_s unless payload['priority'].nil?

          options = payload['options'] || {}
          MONITOR_OPTION_MAP.each do |api_key, tf_key|
            next unless options.key?(api_key)

            value = options[api_key]
            next if value.nil?

            attrs[tf_key] = value
          end

          # The provider declares notify_no_data and no_data_timeframe MUTUALLY
          # EXCLUSIVE with on_missing_data (which supersedes them), and the API
          # returns them together. Emitting both is a hard "Conflicting
          # configuration arguments" error, not a diff -- the same shape as the
          # downtime monitor_id/monitor_tags conflict.
          if attrs.key?(:on_missing_data)
            attrs.delete(:notify_no_data)
            attrs.delete(:no_data_timeframe)
          end

          canonicalize(attrs)
        end

        # Anything the API returned that the projection above did not consume.
        # A non-empty result means the emitted code cannot be a faithful
        # representation, so verify treats it as a failure rather than a note.
        def monitor_unmapped(payload)
          top = payload.keys - MONITOR_SERVER_FIELDS - %w[
            name type query message tags restricted_roles draft_status priority options
          ]
          opts = (payload['options'] || {}).keys - MONITOR_OPTION_MAP.keys - MONITOR_SERVER_OPTIONS
          known, unknown = opts.partition { |o| MONITOR_PROVIDER_UNSUPPORTED.key?(o) }
          { fields: top.sort, options: unknown.sort, unmanageable: known.sort }
        end

        # ---- dashboards --------------------------------------------------

        def dashboard(payload)
          attrs = {}
          DASHBOARD_FIELD_MAP.each do |api_key, tf_key|
            next unless payload.key?(api_key)

            value = payload[api_key]
            next if value.nil?
            next if tf_key == :description && value.to_s.empty?

            attrs[tf_key] = tf_key == :widget ? strip_widget_ids(value) : value
          end
          canonicalize(attrs)
        end

        def dashboard_unmapped(payload)
          (payload.keys - DASHBOARD_FIELD_MAP.keys - DASHBOARD_SERVER_FIELDS).sort
        end

        # ---- dashboards, the JSON path ------------------------------------
        #
        # The typed datadog_dashboard resource CANNOT carry a live dashboard.
        # Its `widget` attribute is Array(Hash) at the Ruby type layer, which
        # accepts the API shape, but the terraform provider's widget schema is a
        # PER-TYPE BLOCK structure (timeseries_definition, group_definition,
        # query_value_definition, ...) and terraform rejects the API's
        # {definition, layout} outright: "No argument or block type is named
        # definition". Verified against DataDog/datadog 4.10.0.
        #
        # datadog_dashboard_json takes the body verbatim as a string and DOES
        # round-trip to an empty plan. The provider stores its own canonical
        # form, so the body must be reduced to exactly the keys below or every
        # plan diffs forever. Discovered by reading what the provider itself
        # wrote to terraform state, not by guessing.
        # The dashboard_json body has two valid shapes and the provider picks
        # per object. FOUR rules were measured with `roundtrip` against the live
        # estate, and the naive-looking one wins:
        #
        #   carry restricted_roles always      2 of 8   clean
        #   drop both always                   4 of 6   clean
        #   tags heuristic (SHIPPED)           7 of 10  clean
        #   mirror the provider's own source   2 of 10  clean
        #   emit the API payload verbatim      2 of 10  clean
        #
        # That last line is the interesting one. The provider's normalization is
        # readable (terraform-provider-datadog v4.10.0,
        # datadog/resource_datadog_dashboard_json.go: delete every widget id,
        # sort notify_list, and `restricted_roles` present-and-an-array deletes
        # is_read_only, else is_read_only=false). Applying it EXACTLY made
        # matters WORSE, which means the provider does not apply it symmetrically
        # to config and state -- pre-normalizing the config double-applies it and
        # diverges from a state that was normalized once.
        #
        # WHY NO STATIC RULE CAN WIN, established from the source: `prepResource`
        # runs on BOTH sides - as the schema's StateFunc over the config, and
        # again in updateDashboardJSONState over the read response - and it is
        # deterministic. Identical inputs MUST therefore compare equal. They do
        # not, which means the body the provider reads back differs per dashboard
        # from what `GET /api/v1/dashboard/{id}` gave us. No transformation of
        # OUR payload can close a gap between two different payloads.
        #
        # THE ONLY COMPLETE FIX is to derive the emitted body from the provider's
        # own post-import state, authoritative by construction, at the cost of
        # making `emit` depend on a terraform round-trip. That is an operator
        # decision, not a silent one.
        #
        # So the shipped rule is a HEURISTIC, knowingly. Known counterexample:
        # 2b5-nmb-xa7 has no tags yet the provider's read wants the
        # restricted_roles shape. `roundtrip` names every board it fails on.
        DASHBOARD_JSON_ENVELOPE = %w[
          id url author_handle author_name created_at modified_at deleted_at
        ].freeze

        # Nothing is unmanageable on this path any more: the body carries
        # whichever of restricted_roles / is_read_only the provider expects.
        DASHBOARD_PROVIDER_UNSUPPORTED = {}.freeze

        # Keys are sorted so the emitted string is canonical. Without this the
        # body an archetype engine BUILDS and the body absorbed from the API
        # serialize to different strings for identical content, and the oracle
        # reports a diff that is pure key order. The provider parses the string,
        # so ordering is immaterial to terraform -- re-verified against the live
        # estate after this change.
        def dashboard_json_body(payload)
          dashboard_json_shape(payload.reject { |k, _| DASHBOARD_JSON_ENVELOPE.include?(k) })
        end

        # Shared by the absorbed path and by any archetype engine that BUILDS a
        # body, so both produce the same shape. Keeping this in one place is what
        # the oracle enforces: when only the absorbed path had the rule, the five
        # archetype dashboards diffed immediately.
        def dashboard_json_shape(body)
          shaped = body.dup

          if shaped.key?('tags')
            shaped.delete('is_read_only')
            shaped['restricted_roles'] ||= []
          else
            shaped.delete('restricted_roles')
            shaped['is_read_only'] = false unless shaped.key?('is_read_only')
          end

          deep_sort(shaped)
        end

        def dashboard_json(payload)
          { dashboard: JSON.generate(dashboard_json_body(payload)) }
        end

        # Prefers a recorded provider-normalized body when one exists. Emit and
        # verify BOTH route through this, so they can never disagree about which
        # body a dashboard has.
        def dashboard_json_for(payload, normalized)
          return dashboard_json(payload) if normalized.nil?

          { dashboard: JSON.generate(deep_sort(normalized)) }
        end

        # Nothing can be silently lost on the JSON path -- the body is carried
        # verbatim -- so the only reportable gap is what the provider drops.
        def dashboard_json_unmanageable(payload)
          DASHBOARD_PROVIDER_UNSUPPORTED.keys.select do |k|
            payload.key?(k) && !blank?(payload[k])
          end
        end

        # Widget groups nest a child widget list, so this recurses. 202 group
        # widgets across the estate sit above 2441 widgets total; a shallow
        # strip would leave ids buried two levels down.
        def strip_widget_ids(widgets)
          Array(widgets).map do |widget|
            out = {}
            widget.each do |key, value|
              next if WIDGET_SERVER_FIELDS.include?(key)

              out[key] = if key == 'definition' && value.is_a?(Hash) && value.key?('widgets')
                           nested = value.dup
                           nested['widgets'] = strip_widget_ids(value['widgets'])
                           nested
                         else
                           value
                         end
            end
            out
          end
        end

        # ---- SLOs ---------------------------------------------------------

        SLO_FIELD_MAP = {
          'name' => :name,
          'type' => :type,
          'description' => :description,
          'thresholds' => :thresholds,
          'tags' => :tags,
          'target_threshold' => :target_threshold,
          'timeframe' => :timeframe,
          'query' => :query,
          'sli_specification' => :sli_specification,
          'groups' => :groups,
          'monitor_ids' => :monitor_ids,
          'warning_threshold' => :warning_threshold
        }.freeze

        SLO_SERVER_FIELDS = %w[id created_at creator modified_at type_id].freeze

        # In the provider schema but never returned by the API -- they are
        # terraform-side behaviour flags, not estate content.
        SLO_PROVIDER_ONLY = %w[force_delete validate].freeze

        SLO_PROVIDER_UNSUPPORTED = {
          'monitor_tags' => 'not present in the datadog_service_level_objective provider schema'
        }.freeze

        # Inside a thresholds block these are COMPUTED by the provider, so
        # setting them is a hard "Value for unconfigurable attribute" error even
        # though the API returns them. Same class as a server-assigned widget id.
        SLO_THRESHOLD_COMPUTED = %w[target_display warning_display].freeze

        # The API's sli_specification is a plain nested hash; the provider models
        # it as BLOCKS, and the two shapes disagree in three specific ways:
        #
        #   good_events_formula   API {"formula" => "x"}   provider a bare String
        #   total_events_formula  API {"formula" => "x"}   provider a bare String
        #   queries               API [{name, query, ...}] provider a list of
        #                         blocks each wrapping a `metric_query` block
        #
        # Terraform rejects the API shape outright ("Extraneous JSON object
        # property"), so this reshape is what makes a metric SLO adoptable at
        # all. Verified against DataDog/datadog 4.10.0.
        def slo_sli_specification(spec)
          count = spec['count']
          return spec unless count.is_a?(Hash)

          rebuilt = {}
          %w[good_events_formula total_events_formula bad_events_formula].each do |key|
            value = count[key]
            next if value.nil?

            rebuilt[key] = value.is_a?(Hash) ? value['formula'] : value
          end
          rebuilt['queries'] = Array(count['queries']).map { |q| { 'metric_query' => [q] } }

          { 'count' => [rebuilt] }
        end

        def slo(payload)
          attrs = {}
          SLO_FIELD_MAP.each do |api_key, tf_key|
            next unless payload.key?(api_key)

            value = payload[api_key]
            next if value.nil?
            next if value.respond_to?(:empty?) && value.empty? && tf_key != :thresholds

            attrs[tf_key] =
              case tf_key
              when :thresholds
                Array(value).map { |t| t.reject { |k, _| SLO_THRESHOLD_COMPUTED.include?(k) } }
              when :sli_specification
                [slo_sli_specification(value)]
              else
                value
              end
          end

          # The provider documents `query` as an ALTERNATIVE to
          # sli_specification, so carrying both is a conflict. The API returns
          # both for a count-based SLO; sli_specification is the richer one.
          attrs.delete(:query) if attrs.key?(:sli_specification)

          canonicalize(attrs)
        end

        def slo_unmapped(payload)
          leftover = payload.keys - SLO_FIELD_MAP.keys - SLO_SERVER_FIELDS - SLO_PROVIDER_ONLY
          known, unknown = leftover.partition { |k| SLO_PROVIDER_UNSUPPORTED.key?(k) }
          # An empty monitor_tags is absence, not an unmanaged value.
          known = known.reject { |k| blank?(payload[k]) }
          { fields: unknown.sort, unmanageable: known.sort }
        end

        # ---- downtimes ----------------------------------------------------
        #
        # The API returns the v1 downtime shape and the provider still carries
        # the matching v1 `datadog_downtime` resource, so this is a direct
        # mapping. `datadog_downtime_schedule` is the v2 resource with a
        # different model (one_time_schedule / recurring_schedule /
        # monitor_identifier) and is NOT what a v1 payload projects onto.

        DOWNTIME_FIELD_MAP = {
          'scope' => :scope,
          'message' => :message,
          'monitor_id' => :monitor_id,
          'monitor_tags' => :monitor_tags,
          'mute_first_recovery_notification' => :mute_first_recovery_notification,
          'recurrence' => :recurrence,
          'start' => :start,
          'end' => :end,
          'timezone' => :timezone
        }.freeze

        # Lifecycle and identity Datadog owns. `active`/`canceled`/`disabled`/
        # `status` are runtime state: a downtime that has expired is not a
        # different declaration, it is the same declaration later.
        DOWNTIME_SERVER_FIELDS = %w[
          id uuid child_id parent_id org_id creator_id updater_id
          created modified active canceled disabled status downtime_type
        ].freeze

        DOWNTIME_PROVIDER_UNSUPPORTED = {
          'notify_end_states' => 'not present in the v1 datadog_downtime provider schema',
          'notify_end_types' => 'not present in the v1 datadog_downtime provider schema'
        }.freeze

        # Datadog's "match every monitor" sentinel for monitor_tags. It is the
        # ABSENCE of a tag filter, not a tag filter matching everything, and the
        # provider declares monitor_tags mutually exclusive with monitor_id --
        # so emitting it alongside a monitor_id is a hard "Conflicting
        # configuration arguments" error. All 18 downtimes in the measured
        # estate carry both.
        DOWNTIME_ALL_MONITORS = ['*'].freeze

        def downtime(payload)
          attrs = {}
          scoped_to_monitor = !payload['monitor_id'].nil?

          DOWNTIME_FIELD_MAP.each do |api_key, tf_key|
            next unless payload.key?(api_key)

            value = payload[api_key]
            next if value.nil?
            next if value.respond_to?(:empty?) && value.empty?
            next if tf_key == :monitor_tags && (scoped_to_monitor || Array(value) == DOWNTIME_ALL_MONITORS)

            # The provider types scope as a list; the API may return a scalar.
            attrs[tf_key] = tf_key == :scope ? Array(value) : value
          end
          canonicalize(attrs)
        end

        def downtime_unmapped(payload)
          leftover = payload.keys - DOWNTIME_FIELD_MAP.keys - DOWNTIME_SERVER_FIELDS
          known, unknown = leftover.partition { |k| DOWNTIME_PROVIDER_UNSUPPORTED.key?(k) }
          known = known.reject { |k| blank?(payload[k]) }
          { fields: unknown.sort, unmanageable: known.sort }
        end

        # ---- comparison --------------------------------------------------

        # Order-insensitive where Datadog is order-insensitive (tags), stable
        # everywhere else. Widget order is meaningful (it is the layout), so it
        # is preserved.
        def canonicalize(attrs)
          out = {}
          attrs.keys.sort.each do |key|
            value = attrs[key]
            out[key] = key == :tags ? Array(value).sort : deep_sort(value)
          end
          out
        end

        def deep_sort(value)
          case value
          when Hash
            value.keys.sort_by(&:to_s).each_with_object({}) { |k, h| h[k] = deep_sort(value[k]) }
          when Array
            value.map { |v| deep_sort(v) }
          else
            value
          end
        end

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end

        # A stable content fingerprint, used to detect that two live objects are
        # the same dashboard cloned rather than two genuinely distinct boards.
        def fingerprint(attrs)
          require 'digest'
          Digest::SHA256.hexdigest(JSON.generate(attrs))
        end
      end
    end
  end
end
