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
        Error = Class.new(StandardError)

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

        # The API nests a LIST under `recurrences`; the provider names the same
        # thing `recurrence` and models it as repeated blocks. Passing the API
        # shape through verbatim produced `No argument or block type is named
        # "recurrences"` -- a hard plan error, invisible to attribute-level
        # state matching because both sides carried the same wrong key.
        MONITOR_RECURRENCE_FIELDS = %w[rrule start timezone].freeze

        def monitor_scheduling_options(value)
          return value unless value.is_a?(Hash)

          out = value.dup
          custom = out['custom_schedule'] || out[:custom_schedule]
          return out unless custom.is_a?(Hash)

          recurrences = custom['recurrences'] || custom[:recurrences]
          return out if recurrences.nil?

          out['custom_schedule'] = {
            'recurrence' => Array(recurrences).map { |r| compact_symbolized(r, MONITOR_RECURRENCE_FIELDS) }
          }
          out
        end

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

          if attrs.key?(:scheduling_options)
            attrs[:scheduling_options] = monitor_scheduling_options(attrs[:scheduling_options])
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
          { dashboard: escape_terraform_templates(JSON.generate(dashboard_json_body(payload))) }
        end

        # Prefers a recorded provider-normalized body when one exists. Emit and
        # verify BOTH route through this, so they can never disagree about which
        # body a dashboard has.
        def dashboard_json_for(payload, normalized)
          return dashboard_json(payload) if normalized.nil?

          { dashboard: escape_terraform_templates(JSON.generate(deep_sort(normalized))) }
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
        # The single tail every attribute body passes through: stable key order,
        # stable nested order, and terraform-literal text. Escaping here rather
        # than at each call site is what keeps emit, verify and roundtrip from
        # disagreeing about what the body says.
        def canonicalize(attrs)
          out = {}
          attrs.keys.sort.each do |key|
            value = attrs[key]
            out[key] = key == :tags ? Array(value).sort : deep_sort(value)
          end
          escape_terraform_templates(out)
        end

        # ── the logs configuration layer ─────────────────────────────────

        # A log processor's provider block name is its API type with dashes
        # swapped for underscores, and each block carries only the fields the
        # provider declares. Verified against the real provider schema
        # (DataDog/datadog 4.10.0, `terraform providers schema -json`), not
        # inferred: `geo-ip-parser` returns `ip_processing_behavior` from the
        # API and the provider models no such field, so keeping it would emit a
        # body terraform rejects.
        #
        # An unknown type RAISES. A silently dropped processor changes what a
        # pipeline does to every log flowing through it, and would state-match
        # perfectly while doing it -- the emitted code simply would not mention
        # the processor, and verify only checks what the code declares.
        LOGS_PROCESSOR_FIELDS = {
          'arithmetic_processor' => %w[expression is_enabled is_replace_missing name target],
          'attribute_remapper' => %w[is_enabled name override_on_conflict preserve_source source_type
                                     sources target target_format target_type],
          'category_processor' => %w[is_enabled name target],
          'date_remapper' => %w[is_enabled name sources],
          'geo_ip_parser' => %w[is_enabled name sources target],
          'grok_parser' => %w[is_enabled name samples source],
          'message_remapper' => %w[is_enabled name sources],
          'service_remapper' => %w[is_enabled name sources],
          'status_remapper' => %w[is_enabled name sources],
          'url_parser' => %w[is_enabled name normalize_ending_slashes sources target],
          'user_agent_parser' => %w[is_enabled is_encoded name sources target]
        }.freeze

        # Datadog ships its own integration pipelines (Nginx, MySQL, Redis …)
        # into every account. They are `is_read_only` and the provider models
        # them as a DIFFERENT resource carrying only `is_enabled` -- emitting one
        # as a custom pipeline would try to recreate Datadog's own pipeline
        # alongside it. 9 of this estate's 12 pipelines are of this kind.
        def logs_pipeline_read_only?(payload)
          payload['is_read_only'] == true
        end

        def logs_integration_pipeline(payload)
          { is_enabled: payload['is_enabled'] == true }
        end

        def logs_custom_pipeline(payload)
          canonicalize(
            name: payload['name'].to_s,
            is_enabled: payload['is_enabled'] == true,
            filter: [{ query: payload.dig('filter', 'query').to_s }],
            processor: Array(payload['processors']).map { |p| logs_processor(p) }
          )
        end

        def logs_processor(processor)
          block = processor['type'].to_s.tr('-', '_')
          fields = LOGS_PROCESSOR_FIELDS[block]
          raise Error, "unknown log processor type #{processor['type'].inspect}" if fields.nil?

          body = fields.each_with_object({}) do |f, h|
            h[f.to_sym] = processor[f] unless processor[f].nil?
          end
          body[:grok] = [logs_grok(processor['grok'])] if block == 'grok_parser'
          body[:category] = logs_categories(processor['categories']) if block == 'category_processor'

          { block.to_sym => [body] }
        end

        def logs_grok(grok)
          { support_rules: grok.to_h['support_rules'].to_s,
            match_rules: grok.to_h['match_rules'].to_s }
        end

        def logs_categories(categories)
          Array(categories).map do |c|
            { name: c['name'].to_s, filter: [{ query: c.dig('filter', 'query').to_s }] }
          end
        end

        # A logs metric's API `id` IS its name, and its real body hides under
        # `attributes`.
        def logs_metric(payload)
          attributes = payload['attributes'] || {}
          attrs = {
            name: payload['id'].to_s,
            filter: [{ query: attributes.dig('filter', 'query').to_s }],
            compute: [compact_symbolized(attributes['compute'], %w[aggregation_type include_percentiles path])]
          }
          group_by = Array(attributes['group_by'])
                     .map { |g| compact_symbolized(g, %w[path tag_name]) }
          attrs[:group_by] = group_by unless group_by.empty?
          canonicalize(attrs)
        end

        # An index cannot be CREATED through the API at all, so this body only
        # ever describes something already there -- which is exactly absorb's
        # model. The API's names differ from the provider's on three fields.
        def logs_index(payload)
          attrs = {
            name: payload['name'].to_s,
            filter: [{ query: payload.dig('filter', 'query').to_s }],
            retention_days: payload['num_retention_days'],
            disable_daily_limit: payload['daily_limit'].nil?
          }
          attrs[:daily_limit] = payload['daily_limit'] unless payload['daily_limit'].nil?
          unless payload['num_flex_logs_retention_days'].nil?
            attrs[:flex_retention_days] = payload['num_flex_logs_retention_days']
          end
          unless payload['daily_limit_warning_threshold_percentage'].nil?
            attrs[:daily_limit_warning_threshold_percentage] =
              payload['daily_limit_warning_threshold_percentage']
          end
          reset = payload['daily_limit_reset']
          attrs[:daily_limit_reset] = [compact_symbolized(reset, %w[reset_time reset_utc_offset])] if reset
          filters = Array(payload['exclusion_filters']).map { |f| logs_exclusion_filter(f) }
          attrs[:exclusion_filter] = filters unless filters.empty?
          canonicalize(attrs.compact)
        end

        def logs_exclusion_filter(payload)
          { name: payload['name'].to_s,
            is_enabled: payload.dig('filter', 'sample_rate') ? true : payload['is_enabled'] == true,
            filter: [{ query: payload.dig('filter', 'query').to_s,
                       sample_rate: payload.dig('filter', 'sample_rate') }.compact] }
        end

        # ── sidecar fidelity ─────────────────────────────────────────────
        #
        # A reconciled object has a hole in the gate. emit ships the sidecar AND
        # verify derives its expectation from the sidecar, so the two agree by
        # construction -- a comparison that cannot fail, covering 48 dashboards
        # and 9 powerpacks.
        #
        # The failure that hole hides is STALENESS. reconcile records the
        # provider's read at time T; someone edits the object in Datadog at T+1;
        # a re-capture refreshes the raw API payload but leaves the sidecar
        # untouched; emit ships the old body and verify passes green while the
        # generated code no longer describes the estate -- exactly what the
        # oracle exists to prevent.
        #
        # These are facts BOTH reads must report identically. A disagreement
        # means the sidecar no longer describes what was captured, so it is a
        # gate failure, not a warning.
        def sidecar_fidelity(kind, payload, sidecar)
          return [] if sidecar.nil?

          case kind
          when 'datadog_dashboard_json' then dashboard_fidelity(payload, sidecar)
          when 'datadog_powerpack' then powerpack_fidelity(payload, sidecar)
          else []
          end
        end

        def dashboard_fidelity(payload, sidecar)
          disagreements(
            'title' => [payload['title'].to_s, sidecar['title'].to_s],
            'widget_count' => [count_widgets(payload['widgets']), count_widgets(sidecar['widgets'])],
            'widget_titles' => [widget_titles(payload['widgets']), widget_titles(sidecar['widgets'])],
            'template_variables' => [variable_names(payload['template_variables']),
                                     variable_names(sidecar['template_variables'])]
          )
        end

        def powerpack_fidelity(payload, sidecar)
          attributes = payload['attributes'] || {}
          disagreements(
            'name' => [attributes['name'].to_s, sidecar['name'].to_s],
            'widget_count' => [count_widgets(attributes.dig('group_widget', 'definition', 'widgets')),
                               count_widgets_flat(sidecar['widget'])],
            'tags' => [Array(attributes['tags']).sort, Array(sidecar['tags']).sort]
          )
        end

        def disagreements(checks)
          checks.reject { |_, (a, b)| a == b }.keys.sort
        end

        # Groups nest, so a flat count would miss an edit inside one.
        def count_widgets(widgets)
          Array(widgets).sum do |w|
            nested = w.dig('definition', 'widgets')
            1 + count_widgets(nested)
          end
        end

        # The provider's powerpack state is a FLAT widget list -- the API's
        # group wrapper is the powerpack itself -- so counting it recursively
        # would compare a flat list against a nested one.
        def count_widgets_flat(widgets) = Array(widgets).size

        def widget_titles(widgets)
          Array(widgets).flat_map do |w|
            definition = w['definition'] || {}
            [definition['title'].to_s] + widget_titles(definition['widgets'])
          end.reject(&:empty?).sort
        end

        def variable_names(variables)
          Array(variables).map { |v| v['name'].to_s }.sort
        end

        # ── powerpacks ───────────────────────────────────────────────────
        #
        # `datadog_powerpack` models widgets as 31 typed sub-blocks -- the shape
        # that made the typed `datadog_dashboard` unusable -- and unlike
        # dashboards there is no `_json` escape hatch to fall back to. So there
        # is NO viable projection of the API payload: the only body that works
        # is the provider's own post-import state, recorded by `reconcile`.
        #
        # Measured: with the prune below, 9 of 9 of this estate's powerpacks
        # plan to "No changes"; without it, 0 of 9 -- the provider's own state
        # carries values its own schema rejects.
        def powerpack(_payload, normalized)
          return nil if normalized.nil?

          canonicalize(symbolize_deep(normalized))
        end

        # The provider's post-import state is not directly re-usable as config.
        # Three things in it are rejected by the provider's own schema:
        #
        #   ''         not a valid WidgetLiveSpan or legend_size enum value
        #   widget.id  computed, "can't configure a value for"
        #   []/nil     absence, not a declared empty
        #
        # But an empty HASH is a declared block carrying no set fields
        # (toplist_definition.style), and dropping it is itself a diff -- that
        # distinction alone is the difference between 8/9 and 9/9.
        def prune_provider_state(value)
          case value
          when Hash
            value.each_with_object({}) do |(k, v), h|
              next if k.to_s == 'id'

              pruned = prune_provider_state(v)
              next if pruned.nil? || (pruned.respond_to?(:empty?) && pruned.empty? && !pruned.is_a?(Hash))

              h[k] = pruned
            end
          when Array then value.map { |v| prune_provider_state(v) }.compact
          else value
          end
        end

        def symbolize_deep(value)
          case value
          when Hash then value.to_h { |k, v| [k.to_sym, symbolize_deep(v)] }
          when Array then value.map { |v| symbolize_deep(v) }
          else value
          end
        end

        # ── the account layer ────────────────────────────────────────────

        def team(payload)
          a = payload['attributes'] || {}
          canonicalize(name: a['name'].to_s, handle: a['handle'].to_s,
                       description: a['description'].to_s)
        end

        # Datadog ships Admin / Standard / Read Only into every account and
        # marks them `managed`. They are the role equivalent of a read-only
        # integration pipeline -- except the provider has NO resource for them
        # at all, so they are not adoptable and must not be emitted. 3 of this
        # estate's 4 roles are managed.
        def role_managed?(payload)
          payload.dig('attributes', 'managed') == true
        end

        # KNOWN LIMITATION, provider 4.10.0. `terraform import` of a role does
        # not hydrate its `permission` blocks into state, so every permission
        # reads as an addition and the plan never empties -- the same read gap
        # that made the typed `datadog_dashboard` unusable. Emitting it is still
        # right: the code correctly describes the estate, and an apply converges
        # the live role. It is the round trip that is lossy, not the body.
        def role(payload)
          a = payload['attributes'] || {}
          permissions = Array(payload.dig('relationships', 'permissions', 'data'))
                        .map { |p| { id: p['id'].to_s } }
          attrs = { name: a['name'].to_s }
          attrs[:permission] = permissions unless permissions.empty?
          canonicalize(attrs)
        end

        # `client_token` and `api_key_id` are computed by the provider and the
        # list response carries neither secret, so nothing credential-bearing
        # crosses into the emitted code.
        RUM_FIELDS = { 'name' => :name, 'type' => :type }.freeze

        def rum_application(payload)
          a = payload['attributes'] || {}
          canonicalize(RUM_FIELDS.each_with_object({}) do |(api, tf), h|
            h[tf] = a[api] unless a[api].nil?
          end)
        end

        # `datadog_apm_retention_filter` accepts exactly ONE filter_type. Datadog
        # ships defaults using others (spans-errors-sampling-processor,
        # spans-appsec-sampling-processor), and the provider rejects them at
        # validate -- not a diff, a hard error. Both of this estate's filters are
        # of that kind, so both are Datadog's to own.
        APM_FILTER_TYPE = 'spans-sampling-processor'

        def apm_retention_filter_adoptable?(payload)
          payload.dig('attributes', 'filter_type') == APM_FILTER_TYPE
        end

        def apm_retention_filter(payload)
          a = payload['attributes'] || {}
          attrs = {
            name: a['name'].to_s,
            enabled: a['enabled'] == true,
            filter_type: a['filter_type'].to_s,
            rate: a['rate']
          }
          attrs[:filter] = { query: a.dig('filter', 'query').to_s } if a['filter']
          attrs[:trace_rate] = a['trace_rate'] unless a['trace_rate'].nil?
          canonicalize(attrs.compact)
        end

        # A list's membership IS the resource; its own record reports
        # `dashboards: null` and the members arrive from a second endpoint.
        def dashboard_list(payload)
          items = Array(payload['dashboards']).map do |d|
            { dash_id: d['id'].to_s, type: d['type'].to_s }
          end
          attrs = { name: payload['name'].to_s }
          attrs[:dash_item] = items unless items.empty?
          canonicalize(attrs)
        end

        ACCOUNT_STRUCTURAL = {
          'datadog_team' => %w[id type],
          'datadog_role' => %w[id type relationships],
          'datadog_rum_application' => %w[id type],
          'datadog_apm_retention_filter' => %w[id type],
          'datadog_dashboard_list' => %w[id type name dashboards]
        }.freeze

        # Server-owned counters and audit stamps. Reported as unmanageable
        # rather than as oversights, because no provider models them and
        # authoring them would be meaningless.
        ACCOUNT_SERVER_ATTRS = %w[created_at modified_at created created_by modified modified_by
                                  created_by_handle modified_by_handle updated_by_handle
                                  user_count team_count link_count is_managed managed
                                  provisioned_by summary editable execution_order
                                  org_id updated_at author dashboard_count is_favorite
                                  application_id api_key_id client_token is_active
                                  ootb_metrics_installed short_name product_scales].freeze

        # Real, authored state the provider declines to model. A RUM
        # application's tags and its replay sampling rates are configuration
        # someone chose, and `datadog_rum_application` carries only name and
        # type -- so adopting one silently leaves those settings unmanaged.
        # Saying so is the difference between a gap and a surprise.
        ACCOUNT_UNMANAGEABLE = {
          'datadog_rum_application' => %w[tags product_analytics_replay_sample_rate
                                          error_tracking_exclusion_filter_enabled
                                          apm_rum_flat_sampling_replay_enabled
                                          apm_rum_flat_sampling_replay_sample_rate]
        }.freeze

        def account_unmapped(kind, payload)
          structural = ACCOUNT_STRUCTURAL.fetch(kind, [])
          attrs = payload['attributes'].is_a?(Hash) ? payload['attributes'] : payload
          unmanageable = ACCOUNT_UNMANAGEABLE.fetch(kind, [])
          leftover = attrs.keys - structural - account_mapped_keys(kind) -
                     ACCOUNT_SERVER_ATTRS - unmanageable
          present = unmanageable.select { |k| attrs.key?(k) && !blank?(attrs[k]) }
          { fields: leftover.sort, unmanageable: present.sort }
        end

        ACCOUNT_MAPPED = {
          'datadog_team' => %w[name handle description],
          'datadog_role' => %w[name],
          'datadog_rum_application' => %w[name type],
          'datadog_apm_retention_filter' => %w[name enabled filter_type rate filter trace_rate],
          'datadog_dashboard_list' => %w[name dashboards]
        }.freeze

        def account_mapped_keys(kind) = ACCOUNT_MAPPED.fetch(kind, [])

        # Structural keys carry the object's identity or discriminate which
        # resource it becomes. They are consumed by the emitter, not lost, so
        # reporting them as oversights would be noise.
        LOGS_STRUCTURAL = {
          'datadog_logs_custom_pipeline' => %w[id type is_read_only name is_enabled filter processors],
          'datadog_logs_integration_pipeline' => %w[id type is_enabled],
          'datadog_logs_metric' => %w[id type attributes],
          'datadog_logs_index' => %w[name filter num_retention_days daily_limit daily_limit_reset
                                     daily_limit_warning_threshold_percentage exclusion_filters
                                     num_flex_logs_retention_days]
        }.freeze

        # Real state the provider declines to model, reported so the gap is
        # visible rather than discovered later. A read-only integration pipeline
        # is mostly this: the provider exposes only its on/off switch, so its
        # name, filter and processors are Datadog's to own, not ours.
        LOGS_UNMANAGEABLE = {
          'datadog_logs_custom_pipeline' => %w[],
          'datadog_logs_integration_pipeline' => %w[name filter processors is_read_only],
          'datadog_logs_metric' => %w[],
          'datadog_logs_index' => %w[is_rate_limited]
        }.freeze

        def logs_unmapped(kind, payload)
          structural = LOGS_STRUCTURAL.fetch(kind, [])
          unmanageable = LOGS_UNMANAGEABLE.fetch(kind, [])
          leftover = payload.keys - structural - unmanageable
          present = unmanageable.select { |k| payload.key?(k) && !blank?(payload[k]) }
          { fields: leftover.sort, unmanageable: present.sort }
        end

        # Terraform parses every JSON string value as a TEMPLATE, so `${` opens
        # an interpolation and `%{` opens a directive. Absorbed text is data --
        # a grok rule `%{date("..."):date}`, a monitor named
        # `Site24x7 ${{event.host.name}}` -- and terraform reads both as syntax,
        # failing the plan outright.
        #
        # Escaping is safe HERE and nowhere else in Pangea: absorb never emits an
        # intentional interpolation, so every string it produces is literal by
        # construction. The general renderer cannot do this, because there a
        # `${datadog_monitor.x.id}` reference is meant to interpolate.
        #
        # Idempotent by construction -- the lookbehinds skip an already-escaped
        # sequence, so applying it twice cannot produce `%%%{`.
        def escape_terraform_templates(value)
          case value
          when String then value.gsub(/(?<!\$)\$\{/, '$${').gsub(/(?<!%)%\{/, '%%{')
          when Array then value.map { |v| escape_terraform_templates(v) }
          when Hash then value.transform_values { |v| escape_terraform_templates(v) }
          else value
          end
        end

        def compact_symbolized(hash, keys)
          keys.each_with_object({}) do |k, h|
            v = hash.to_h[k]
            h[k.to_sym] = v unless v.nil?
          end
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
