# frozen_string_literal: true

module Pangea
  module Architectures
    module Datadog
      # Rung 3: a real archetype, derived from the estate rather than imagined.
      #
      # Five boards in the akeyless estate -- DBK Staging, DBK Staging
      # (Estimation), WMT Staging, WMT Production (Estimation) and DBK
      # Production (Estimation) -- are the same dashboard five times over: four
      # CloudSQL timeseries, same metrics, same order, same layout. Twenty
      # duplicated widget bodies collapse to one spec plus five declarations,
      # and `pangea-datadog-absorb verify` proves the collapse changed nothing.
      #
      # THE SPEC BELOW IS MEASURED, NOT DESIGNED. A first version of this file
      # assumed the obvious thing -- four identical widgets on a 2x2 grid, one
      # query name -- and verify rejected it on five separate counts. The boards
      # are actually two half-width widgets above two full-width ones; legend
      # layout changes halfway down; the query names run query1, query2, query3,
      # query3 (widgets 2 and 3 share a name, a copy-paste artifact in the
      # original); and an empty `time` key is present on some widgets and absent
      # on others with no pattern at all.
      #
      # All of that is reproduced rather than corrected. Absorbing an estate
      # means representing what is there; tidying it is a separate change that
      # should show up as a deliberate, reviewable diff and not ride in on a
      # refactor that claims to be behaviour-preserving.
      #
      # A caution from the same estate: the other apparent family, the six
      # "Akeyless - Tenant <X> Overview" boards, is NOT an archetype. Those
      # share a convention -- the same template variables, an overview KPI
      # group, then per-cloud AWS/GCP/Azure groups -- but range from 42 to 97
      # widgets over entirely different metrics. A shared skeleton is not a
      # shared dashboard, and parameterising one into the other would invent
      # content nobody wrote.
      module CloudSqlUnifiedDbs
        GROUP_BY = 'database_id'

        WIDGETS = [
          { metric: 'gcp.cloudsql.database.cpu.utilization',
            query: 'query1', legend: 'vertical',
            layout: { 'x' => 0, 'y' => 0, 'width' => 6, 'height' => 5 } },
          { metric: 'gcp.cloudsql.database.memory.utilization',
            query: 'query2', legend: 'vertical',
            layout: { 'x' => 6, 'y' => 0, 'width' => 6, 'height' => 5 } },
          { metric: 'gcp.cloudsql.database.disk.bytes_used',
            query: 'query3', legend: 'horizontal',
            layout: { 'x' => 0, 'y' => 5, 'width' => 12, 'height' => 3 } },
          { metric: 'gcp.cloudsql.database.disk.utilization',
            query: 'query3', legend: 'horizontal',
            layout: { 'x' => 0, 'y' => 8, 'width' => 12, 'height' => 3 } }
        ].freeze

        # scope is the literal tag filter, carried verbatim. The live boards
        # differ in whitespace ("project_id:x , database_id:y" against
        # "project_id:x,database_id:y") and reproducing them byte for byte
        # matters more than tidying them, for the same reason as above.
        #
        # time_on lists the widget indices carrying the empty `time` key. It has
        # no meaning in Datadog; it is an artifact of how each board was edited,
        # and it is a parameter only because the estate made it one.
        # scope_overrides maps a widget index to its own scope string. Exactly
        # one board needs it: WMT Staging's fourth widget drops the spaces its
        # three siblings carry, writing "project_id:x,!database_id:y" where they
        # write "project_id:x , ! database_id:y". Datadog reads both the same
        # way. A human typed one of them differently, and an archetype that
        # quietly unified them would be rewriting the estate under cover of a
        # refactor -- so the difference is carried, and named.
        def self.build(synth, name:, title:, scope:, time_on: (0...WIDGETS.size).to_a,
                       scope_overrides: {}, layout_type: 'ordered', reflow_type: 'fixed')
          synth.datadog_dashboard(name, {
            layout_type: layout_type,
            notify_list: [],
            reflow_type: reflow_type,
            restricted_roles: [],
            template_variable: [],
            title: title,
            widget: WIDGETS.each_with_index.map do |spec, i|
              widget(spec, scope_overrides.fetch(i, scope), time_on.include?(i))
            end
          })
        end

        def self.widget(spec, scope, with_time)
          definition = {
            'legend_columns' => %w[avg min max value sum],
            'legend_layout' => spec[:legend],
            'requests' => [request(spec, scope)],
            'show_legend' => true,
            'title' => '',
            'title_align' => 'left',
            'title_size' => '16',
            'type' => 'timeseries'
          }
          definition['time'] = {} if with_time

          { 'definition' => definition, 'layout' => spec[:layout] }
        end

        def self.request(spec, scope)
          {
            'display_type' => 'line',
            'formulas' => [{ 'formula' => spec[:query] }],
            'queries' => [{
              'data_source' => 'metrics',
              'name' => spec[:query],
              'query' => "avg:#{spec[:metric]}{#{scope}} by {#{GROUP_BY}}"
            }],
            'response_format' => 'timeseries',
            'style' => {
              'line_type' => 'solid',
              'line_width' => 'normal',
              'palette' => 'dog_classic'
            }
          }
        end
      end
    end
  end
end
