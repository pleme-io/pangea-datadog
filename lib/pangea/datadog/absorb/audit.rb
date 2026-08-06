# frozen_string_literal: true

require 'json'
require 'date'

module Pangea
  module Datadog
    module Absorb
      # A correctness audit of the captured estate, as a side effect of having
      # absorbed it.
      #
      # This exists because adoption already found these defects by accident.
      # Terraform refused to plan three monitors, the refusal traced to Datadog's
      # own validator, and the validator named the reason. A query that cannot
      # validate cannot evaluate -- so the same check, run over the whole
      # capture, finds every instance rather than the ones that happened to
      # block a plan.
      #
      # READ-ONLY AND OFFLINE. Everything here is computed from a capture already
      # on disk. No API call, no credentials, nothing to approve.
      #
      # THE DISTINCTION THIS TURNS ON, and getting it wrong makes the audit
      # useless: a BROKEN monitor and a SILENT one are not the same thing.
      #
      #   broken  its query cannot resolve, so it can never evaluate. A defect.
      #   silent  it is in No Data. For anything ephemeral that is the HEALTHY
      #           state -- "Pod Crashloop" in No Data means nothing is
      #           crashlooping. Not a defect.
      #
      # Only the first fails the gate. An audit that cried wolf on every healthy
      # ephemeral monitor would be ignored within a week, and then the real
      # defects would be ignored with it.
      module Audit
        # An SLO alert names its SLO by id and a timeframe, and Datadog rejects
        # the query outright when that SLO carries no threshold for it.
        #
        # The id is matched as "anything but a quote", not as hex. Real ids are
        # 32-char hex today, and pinning that would mean any other id format
        # silently stops being checked -- an audit that goes quiet is worse than
        # one that never existed.
        SLO_ALERT = /error_budget\("([^"]+)"\)\.over\("([^"]+)"\)/

        # Datadog rejects a service check that carries no grouping:
        # "A grouping must be specified for custom checks". Measured across the
        # estate's 6 service checks -- 5 carry `.by(...)` and validate, the one
        # that does not is exactly the monitor terraform refused to plan.
        GROUP_TYPES = %w[group split_group].freeze
        SERVICE_CHECK = 'service check'
        GROUPING = '.by('

        Finding = Struct.new(:id, :name, :detail, keyword_init: true)

        Result = Struct.new(:broken, :dangling, :silent, :clusters, :monitors, keyword_init: true) do
          def ok? = broken.empty? && dangling.empty?

          def findings
            {
              'monitors' => monitors,
              'broken' => broken.size,
              'silent' => silent.size,
              'dangling' => dangling.size,
              'brokenMonitors' => broken.map { |f| { 'id' => f.id, 'detail' => f.detail } },
              'danglingReferences' => dangling.map { |f| { 'id' => f.id, 'detail' => f.detail } },
              'silentClusters' => clusters.map { |date, names| { 'since' => date, 'count' => names.size } }
            }
          end

          def to_s
            lines = ["audited #{monitors} monitors, broken #{broken.size}, " \
                     "dangling #{dangling.size}, silent #{silent.size}"]
            broken.each { |f| lines << "  BROKEN #{f.id} #{f.name} -- #{f.detail}" }
            dangling.each { |f| lines << "  DANGLING #{f.id} #{f.name} -- #{f.detail}" }
            clusters.each do |date, names|
              lines << "  SILENT since #{date}: #{names.size} monitors went No Data together"
            end
            lines << '  (silent is NOT a defect: No Data is healthy for an ephemeral target)' unless silent.empty?
            lines.join("\n")
          end
        end

        module_function

        def run(capture, today: Date.today)
          slos = slo_timeframes(capture)
          broken = []
          silent = []
          monitors = 0

          capture.each(:monitors) do |_id, payload|
            monitors += 1
            broken.concat(defects(payload, slos))
            entry = silence(payload, today)
            silent << entry if entry
          end

          Result.new(broken: broken.sort_by(&:id), dangling: dangling_references(capture, slos),
                     silent: silent.sort_by { |s| s[:since].to_s },
                     clusters: cluster(silent), monitors: monitors)
        end

        # A dashboard widget pointing at a monitor or SLO that no longer exists.
        #
        # TERRAFORM CANNOT SEE THIS. The dashboard plans perfectly clean: the
        # reference is just a number inside the widget JSON, and the provider has
        # no idea the thing it names was deleted. It renders as a broken widget
        # and nothing anywhere reports it. Found in the live estate: two
        # dashboards still pointing at monitor 106953745, which returns 404.
        #
        # GUARDED ON CAPTURE COMPLETENESS. Against a partial capture -- say
        # `--kinds dashboards` -- every reference would look dangling and the
        # audit would emit a flood of false defects. No monitors captured means
        # no monitor references are checked, and the same for SLOs.
        def dangling_references(capture, slos)
          monitors = capture.ids(:monitors)
          found = []

          capture.each(:dashboards) do |id, payload|
            each_widget(payload['widgets']) do |definition|
              found.concat(widget_references(definition, id, payload, monitors, slos))
            end
          end
          found.concat(dashboard_link_references(capture))
          found.concat(composite_references(capture, monitors))
          found.concat(slo_monitor_references(capture, monitors))
          found.sort_by(&:id)
        rescue Errno::ENOENT
          []
        end

        # A widget's custom_link pointing at a dashboard that no longer exists.
        #
        # Terraform is even blinder to this than to a dead alert_graph: the
        # reference is a URL inside the widget JSON, so nothing anywhere models
        # it as a reference at all. It renders as a link that 404s, and the only
        # person who finds out is whoever clicks it mid-incident.
        #
        # Found live: one dashboard links to 48q-nh9-abz, which returns 404.
        #
        # GUARDED ON CAPTURE COMPLETENESS, and the guard is weaker here than for
        # monitors. A link to a dashboard the capture simply did not fetch looks
        # identical to a link to a deleted one, so a PARTIAL dashboard capture
        # will produce false positives. That is the same exposure the
        # alert_graph check already carries, and the reason both are reported as
        # findings to confirm rather than as facts.
        DASHBOARD_LINK = %r{/dashboard/([a-z0-9]{3}-[a-z0-9]{3}-[a-z0-9]{3})}

        def dashboard_link_references(capture)
          known = capture.ids(:dashboards)
          return [] if known.empty?

          # Counted per (dashboard, target), not per widget. One dashboard
          # linking to the same dead target from several widgets is ONE thing
          # to fix, and emitting the identical line twice reads as a bug in the
          # audit rather than as two widgets.
          hits = Hash.new(0)
          titles = {}
          capture.each(:dashboards) do |id, payload|
            titles[id] = payload['title'].to_s
            each_widget(payload['widgets']) do |definition|
              Array(definition['custom_links']).each do |link|
                match = DASHBOARD_LINK.match(link['link'].to_s)
                next if match.nil? || known.include?(match[1])

                hits[[id, match[1]]] += 1
              end
            end
          end

          hits.map do |(id, target), count|
            widgets = count == 1 ? 'a widget' : "#{count} widgets"
            Finding.new(id: id, name: titles[id],
                        detail: "#{widgets} link to dashboard #{target}, " \
                                'which is not in the estate')
          end
        end

        # A composite monitor names its constituents by id in the query
        # (`12345 && 67890`). One of them being deleted leaves an alert that
        # cannot resolve, and the estate has four composites over twenty
        # references -- all intact today, which is what says this check does not
        # false-positive on real queries.
        COMPOSITE = 'composite'
        MONITOR_ID = /\b(\d{6,})\b/

        def composite_references(capture, monitors)
          return [] if monitors.empty?

          found = []
          capture.each(:monitors) do |_id, payload|
            next unless payload['type'] == COMPOSITE

            payload['query'].to_s.scan(MONITOR_ID).flatten.uniq.each do |ref|
              next if monitors.include?(ref)

              found << Finding.new(id: payload['id'].to_s, name: payload['name'].to_s,
                                   detail: "composite references monitor #{ref}, " \
                                           'which is not in the estate')
            end
          end
          found
        end

        # A monitor-based SLO computes from the monitors it names. One of them
        # being deleted makes the SLO silently wrong rather than obviously
        # broken -- it keeps reporting, on less than it claims.
        def slo_monitor_references(capture, monitors)
          return [] if monitors.empty?

          found = []
          capture.each(:slos) do |_id, payload|
            Array(payload['monitor_ids']).map(&:to_s).each do |ref|
              next if monitors.include?(ref)

              found << Finding.new(id: payload['id'].to_s, name: payload['name'].to_s,
                                   detail: "SLO references monitor #{ref}, which is not in the estate")
            end
          end
          found
        end

        def each_widget(widgets, &block)
          Array(widgets).each do |widget|
            definition = widget['definition'] || {}
            if GROUP_TYPES.include?(definition['type'])
              each_widget(definition['widgets'], &block)
            else
              block.call(definition)
            end
          end
        end

        def widget_references(definition, id, payload, monitors, slos)
          title = payload['title'].to_s
          case definition['type']
          when 'alert_graph'
            alert = definition['alert_id'].to_s
            return [] if monitors.empty? || alert.empty? || monitors.include?(alert)

            [Finding.new(id: id, name: title, detail: "alert_graph widget references monitor #{alert}, " \
                                                      'which is not in the estate')]
          when 'slo', 'slo_list'
            slo = (definition['slo_id'] || definition.dig('query', 'slo_id')).to_s
            return [] if slos.empty? || slo.empty? || slos.key?(slo)

            [Finding.new(id: id, name: title, detail: "#{definition['type']} widget references SLO #{slo}, " \
                                                      'which is not in the estate')]
          else []
          end
        end

        # No rescue. An unreadable SLO capture means this audit cannot answer,
        # and swallowing that would silently downgrade every SLO-alert check to
        # "looks fine" -- the exact failure mode the audit exists to catch.
        def slo_timeframes(capture)
          timeframes = {}
          capture.each(:slos) do |_id, payload|
            timeframes[payload['id']] = Array(payload['thresholds']).filter_map { |t| t['timeframe'] }
          end
          timeframes
        end

        # Every way a monitor can be unable to evaluate. Kept as a list rather
        # than a first-match so one monitor can carry two defects, and so
        # adding a class cannot silently displace another.
        def defects(payload, slos)
          [slo_timeframe_defect(payload, slos), service_check_defect(payload)].compact
        end

        def service_check_defect(payload)
          return nil unless payload['type'] == SERVICE_CHECK

          query = payload['query'].to_s
          return nil if query.empty? || query.include?(GROUPING)

          Finding.new(id: payload['id'].to_s, name: payload['name'].to_s,
                      detail: 'service check carries no grouping; Datadog requires .by(...)')
        end

        def slo_timeframe_defect(payload, slos)
          match = SLO_ALERT.match(payload['query'].to_s)
          return nil if match.nil?

          slo_id, asked = match[1], match[2]
          have = slos[slo_id]
          return nil if have.nil? || have.include?(asked)

          Finding.new(
            id: payload['id'].to_s, name: payload['name'].to_s,
            detail: "asks for #{asked} but SLO #{slo_id} has #{have.empty? ? 'no timeframes' : have.join(', ')}"
          )
        end

        # Recorded, never counted against the gate. `notify_no_data: false` is
        # what makes a silence unannounced -- the monitor will not tell anyone it
        # has stopped watching -- and notification targets are what make anyone
        # believe it is still watching.
        def silence(payload, today)
          return nil unless payload['overall_state'] == 'No Data'

          targets = notification_targets(payload)
          return nil if targets.empty?

          since = payload['overall_state_modified'].to_s[0, 10]
          { id: payload['id'].to_s, name: payload['name'].to_s, since: since,
            days: days_since(since, today), targets: targets.size,
            announces: payload.dig('options', 'notify_no_data') == true }
        end

        def notification_targets(payload)
          payload['message'].to_s.split.select { |word| word.start_with?('@') }.uniq
        end

        def days_since(since, today)
          (today - Date.parse(since)).to_i
        rescue StandardError
          nil
        end

        # A cluster is the signal. Five monitors going No Data on one day is an
        # infrastructure event -- a decommission, or a metric source that moved
        # -- not five independent coincidences. A singleton rarely is.
        def cluster(silent)
          silent.group_by { |s| s[:since] }
                .select { |_, entries| entries.size > 1 }
                .transform_values { |entries| entries.map { |e| e[:name] }.sort }
                .sort.to_h
        end
      end
    end
  end
end
