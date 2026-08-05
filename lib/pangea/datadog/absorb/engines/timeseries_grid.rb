# frozen_string_literal: true

require 'json'
require_relative '../normalize'

module Pangea
  module Datadog
    module Absorb
      module Engines
        # A general archetype engine: N timeseries widgets on a fixed grid, one
        # metric each, sharing a tag scope.
        #
        # The engine is code because building the widget structure is mechanism.
        # The widget TABLE is config, because which metrics on which grid is one
        # organisation's decision. That split is the whole point: this file
        # mentions no metric, no tenant, and no product.
        #
        # It exists because five dashboards in a real estate were the same board
        # five times over. Getting there required measuring rather than assuming,
        # and the irregularities that measurement turned up are why the signature
        # below is shaped the way it is:
        #
        #   scope_overrides  one board's fourth widget wrote its scope with
        #                    different whitespace than its three siblings. Datadog
        #                    reads both identically; a human typed one of them.
        #                    Unifying them would rewrite the estate under cover of
        #                    a refactor.
        #   time_on          an empty `time` key is present on some widgets and
        #                    absent on others, with no pattern. It means nothing to
        #                    Datadog. It is a parameter only because the estate
        #                    made it one.
        #
        # Faithful absorption reproduces both. Tidying them is a separate change
        # that should appear as a deliberate diff, never as a passenger on a
        # refactor claiming to preserve behaviour.
        module TimeseriesGrid
          NAME = 'timeseries_grid'

          module_function

          # widgets is the config table: [{metric, query, legend, layout}, ...]
          # Emits datadog_dashboard_json, not the typed datadog_dashboard. The
          # provider's widget schema is a per-type block structure and rejects
          # the API's {definition, layout} shape outright, so the JSON resource
          # is the only one a live dashboard round-trips through. The body must
          # carry exactly the provider's canonical key set or every plan diffs.
          def build(synth, name:, title:, scope:, widgets:, group_by:,
                    time_on: nil, scope_overrides: {}, widget_ids: [],
                    layout_type: 'ordered', reflow_type: 'fixed',
                    notify_list: [], description: '', template_variables: [])
            present = time_on.nil? ? (0...widgets.size).to_a : time_on

            body = {
              'description' => description,
              'layout_type' => layout_type,
              'notify_list' => notify_list,
              'reflow_type' => reflow_type,
              'template_variables' => template_variables,
              'title' => title,
              'widgets' => widgets.each_with_index.map do |spec, i|
                w = widget(spec, scope_overrides.fetch(i, scope), group_by, present.include?(i))
                # Widget ids are assigned by Datadog and cannot be generated, but
                # the live body carries them, so they ride along as a measured
                # per-instance parameter exactly like time_on and scope_overrides.
                (id = widget_ids[i]) ? w.merge('id' => id) : w
              end
            }
            synth.datadog_dashboard_json(name, { dashboard: JSON.generate(Normalize.dashboard_json_shape(body)) })
          end

          def widget(spec, scope, group_by, with_time)
            definition = {
              'legend_columns' => %w[avg min max value sum],
              'legend_layout' => fetch(spec, 'legend'),
              'requests' => [request(spec, scope, group_by)],
              'show_legend' => true,
              'title' => '',
              'title_align' => 'left',
              'title_size' => '16',
              'type' => 'timeseries'
            }
            definition['time'] = {} if with_time

            { 'definition' => definition, 'layout' => stringify(fetch(spec, 'layout')) }
          end

          def request(spec, scope, group_by)
            query_name = fetch(spec, 'query')
            {
              'display_type' => 'line',
              'formulas' => [{ 'formula' => query_name }],
              'queries' => [{
                'data_source' => 'metrics',
                'name' => query_name,
                'query' => "avg:#{fetch(spec, 'metric')}{#{scope}} by {#{group_by}}"
              }],
              'response_format' => 'timeseries',
              'style' => {
                'line_type' => 'solid',
                'line_width' => 'normal',
                'palette' => 'dog_classic'
              }
            }
          end

          # Config arrives with string keys from YAML; a hand-built spec in a spec
          # file is easier to read with symbols. Accept both.
          def fetch(spec, key)
            spec[key] || spec[key.to_sym]
          end

          def stringify(hash)
            hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
          end
        end
      end
    end
  end
end
