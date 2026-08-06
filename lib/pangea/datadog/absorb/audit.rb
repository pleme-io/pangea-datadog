# frozen_string_literal: true

require 'json'
require 'date'
require 'set'

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

        Result = Struct.new(:broken, :dangling, :silent, :dead, :empty_dashboards, :disabled_pipelines,
                            :dead_metrics, :clusters, :monitors, :diagnosed, :metrics_age_days,
                            keyword_init: true) do
          # `dead` counts. A monitor whose metric stopped reporting cannot fire,
          # so it is a defect in exactly the way `broken` is -- the distinction
          # this audit turns on is CAN IT EVALUATE, and this one cannot.
          def ok? = broken.empty? && dangling.empty? && dead.empty?

          # An EXPLICIT field, not inferred from `dead` being empty. Inferring
          # it meant an undiagnosed run reported `dead 0` and printed no
          # warning, which reads as "none found" rather than "not checked" --
          # the precise confusion this whole audit exists to avoid.
          def diagnosed? = diagnosed

          # The dead/alive verdict is only as current as the metric list behind
          # it. An old list calls live metrics dead with exactly the same
          # confidence as a fresh one, so an unknown or stale age is said out
          # loud rather than trusted quietly.
          def stale_metrics_warning
            if metrics_age_days.nil?
              '  METRIC LIST AGE UNKNOWN -- it carries no timestamp, so dead/alive here ' \
                'cannot be trusted. Re-run `metrics`.'
            elsif metrics_age_days > STALE_AFTER_DAYS
              "  METRIC LIST IS #{metrics_age_days} DAYS OLD -- dead/alive reflects the estate " \
                'as it was then, not now. Re-run `metrics`.'
            end
          end

          def findings
            {
              'monitors' => monitors,
              'broken' => broken.size,
              'silent' => silent.size,
              # NULL, not 0, when the diagnosis did not run. The printed summary
              # says "dead not-checked" for the same reason: a machine reading
              # 0 concludes none were found, which is the confusion this audit
              # exists to prevent, and a receipt that disagrees with the
              # summary is worse than either alone.
              'dead' => diagnosed? ? dead.size : nil,
              'empty' => diagnosed? ? empty_dashboards.size : nil,
              'silenceDiagnosed' => diagnosed?,
              'metricsAgeDays' => metrics_age_days,
              'deadMonitors' => dead.map { |f| { 'id' => f.id, 'detail' => f.detail } },
              'emptyDashboards' => empty_dashboards.map { |f| { 'id' => f.id, 'detail' => f.detail } },
              'disabledPipelines' => disabled_pipelines.map { |f| { 'id' => f.id, 'detail' => f.detail } },
              'deadMetrics' => diagnosed? ? dead_metrics.map { |f| { 'id' => f.id } } : nil,
              'dangling' => dangling.size,
              'brokenMonitors' => broken.map { |f| { 'id' => f.id, 'detail' => f.detail } },
              'danglingReferences' => dangling.map { |f| { 'id' => f.id, 'detail' => f.detail } },
              'silentClusters' => clusters.map { |date, names| { 'since' => date, 'count' => names.size } }
            }
          end

          def to_s
            lines = ["audited #{monitors} monitors, broken #{broken.size}, " \
                     "dangling #{dangling.size}, dead #{diagnosed? ? dead.size : 'not-checked'}, " \
                     "empty #{diagnosed? ? empty_dashboards.size : 'not-checked'}, " \
                     "disabled #{disabled_pipelines.size}, " \
                     "deadmetrics #{diagnosed? ? dead_metrics.size : 'not-checked'}, " \
                     "silent #{silent.size}"]
            broken.each { |f| lines << "  BROKEN #{f.id} #{f.name} -- #{f.detail}" }
            dangling.each { |f| lines << "  DANGLING #{f.id} #{f.name} -- #{f.detail}" }
            dead.each { |f| lines << "  DEAD #{f.id} #{f.name} -- #{f.detail}" }
            empty_dashboards.each { |f| lines << "  EMPTY #{f.id} #{f.name} -- #{f.detail}" }
            unless empty_dashboards.empty?
              lines << '  (empty is clutter, not breakage: it does not fail the gate)'
            end
            disabled_pipelines.each { |f| lines << "  DISABLED #{f.id} #{f.name} -- #{f.detail}" }
            dead_metrics.each { |f| lines << "  DEAD METRIC #{f.id} -- #{f.detail}" }
            unless dead_metrics.empty?
              lines << '  (a defined logs metric that never reports is billed and produces nothing)'
            end
            unless diagnosed?
              lines << '  SILENCE NOT DIAGNOSED -- without --active-metrics every silent monitor ' \
                       'is reported as healthy, including any that can no longer fire'
            end
            lines << stale_metrics_warning if diagnosed? && stale_metrics_warning
            clusters.each do |date, names|
              lines << "  SILENT since #{date}: #{names.size} monitors went No Data together"
            end
            lines << '  (silent is NOT a defect: No Data is healthy for an ephemeral target)' unless silent.empty?
            lines.join("\n")
          end
        end

        module_function

        # `active_metrics` is the set of metric names Datadog has seen report
        # recently. It is OPTIONAL and comes in as data, so this audit stays
        # offline by construction -- the same arrangement conform has with the
        # provider schema. `pangea-datadog-absorb metrics` produces it.
        # STALE_AFTER_DAYS is deliberately short. The dead/silent verdict is a
        # statement about what is reporting NOW, and a metric list from a month
        # ago answers a different question with the same confidence.
        STALE_AFTER_DAYS = 7

        def run(capture, today: Date.today, active_metrics: nil, metrics_age_days: nil)
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

          still_silent, dead = split_silence(capture, silent, active_metrics)

          Result.new(broken: broken.sort_by(&:id), dangling: dangling_references(capture, slos),
                     silent: still_silent.sort_by { |s| s[:since].to_s }, dead: dead,
                     empty_dashboards: empty_dashboards(capture, active_metrics),
                     disabled_pipelines: disabled_pipelines(capture),
                     dead_metrics: dead_metrics(capture, active_metrics),
                     diagnosed: !active_metrics.nil?, metrics_age_days: metrics_age_days,
                     clusters: cluster(still_silent), monitors: monitors)
        end

        # A THIRD CATEGORY, and the reason this matters.
        #
        # This audit's headline claim is that silent is not a defect: No Data is
        # the healthy state for an ephemeral target. That is true right up until
        # the metric itself stops existing, at which point the monitor cannot
        # fire at all and "healthy" is exactly the wrong word.
        #
        # Measured on this estate: 8 of 28 silent monitors query a metric that
        # has not reported in 30 days. Five watch azure.dbformysql_servers.*,
        # two watch gcp.vpn.*. Azure and GCP are both reporting healthily
        # overall -- 371 and 1137 metrics -- so nothing looked broken. The
        # databases and VPN gateways were decommissioned and the alerts stayed.
        # "[gcp] VPN Tunnel is down" cannot tell anyone a VPN tunnel is down.
        #
        # Without the metric list this returns everything as silent and SAYS SO,
        # rather than reporting the healthy reading it cannot justify.
        def split_silence(capture, silent, active_metrics)
          return [silent, []] if active_metrics.nil?

          active = active_metrics.to_set
          dead = []
          alive = []
          silent.each do |entry|
            payload = capture.read(:monitors, entry[:id])
            gone = query_metrics(payload['query']).reject { |name| active.include?(name) }
            if gone.empty?
              alive << entry
            else
              dead << Finding.new(id: entry[:id], name: entry[:name],
                                  detail: "queries #{gone.join(', ')}, which has not reported " \
                                          'recently -- this monitor cannot fire')
            end
          end
          [alive, dead.sort_by(&:id)]
        end

        # A logs metric the estate DEFINES that Datadog has not seen report.
        #
        # The estate defines 8 and 7 of them have never reported: their filters
        # name attributes (@Path, @Method, @RequestDuration) that no log
        # carries, because the log stream that fed them is gone. Two are
        # outright misspellings -- akeyles.path.derive_fragment, and
        # akeyless.access_satus_ok.
        #
        # Reported, not gated: it is dead weight rather than breakage, the same
        # call as an empty dashboard. It is worth surfacing anyway because
        # custom logs metrics are billed per metric whether anything queries
        # them or not, so this one costs money to ignore.
        def dead_metrics(capture, active_metrics)
          return [] if active_metrics.nil?

          active = active_metrics.to_set
          capture.ids(:logs_metrics).reject { |id| active.include?(id.to_s) }.map do |id|
            Finding.new(id: id.to_s, name: id.to_s,
                        detail: 'defined but has not reported recently -- it produces nothing')
          end
        rescue Errno::ENOENT
          []
        end

        # A CUSTOM logs pipeline that is switched off. Its processors do not
        # run, so every attribute it would have extracted is simply absent, and
        # anything downstream that filters on those attributes matches nothing
        # and reports zero -- looking configured and producing nothing.
        #
        # All three of this estate's custom pipelines are disabled, so no
        # custom log processing happens at all. That may well be deliberate,
        # which is why it does NOT fail the gate; it is reported because it is
        # invisible otherwise and because it is the kind of thing that explains
        # other findings.
        #
        # Integration pipelines are excluded: Datadog ships them switched off
        # by default and enabling every one of them is nobody's intent.
        def disabled_pipelines(capture)
          found = []
          capture.each(:logs_pipelines) do |id, payload|
            next if payload['is_read_only']
            next if payload['is_enabled']

            found << Finding.new(id: id, name: payload['name'].to_s,
                                 detail: begin
                                   n = Array(payload['processors']).size
                                   "custom pipeline is disabled, so its #{n} " \
                                     "#{n == 1 ? 'processor never runs' : 'processors never run'} " \
                                     'and the attributes they extract do not exist'
                                 end)
          end
          found.sort_by(&:id)
        rescue Errno::ENOENT
          []
        end

        # A dashboard whose EVERY queried metric has stopped reporting. It
        # renders blank, and a blank dashboard is worse than no dashboard
        # because someone opens it during an incident expecting data.
        #
        # EVERY, not any, and the difference is the whole finding. 15 of this
        # estate's 27 dashboards with metric queries reference at least one dead
        # metric, and reporting those would be crying wolf -- most are cloned
        # out-of-the-box integration boards (AWS, Kubernetes) carrying a few
        # widgets for metrics nobody uses, which is normal. Requiring all of
        # them narrows it to 7, and each of those 7 is genuinely blank.
        #
        # NOT A GATE FAILURE. An empty dashboard is clutter; a monitor that
        # cannot fire is breakage. Only the second kind counts.
        def empty_dashboards(capture, active_metrics)
          return [] if active_metrics.nil?

          active = active_metrics.to_set
          found = []
          capture.each(:dashboards) do |id, payload|
            names = dashboard_metrics(payload)
            next if names.empty?
            next unless names.all? { |name| !active.include?(name) }

            found << Finding.new(id: id, name: payload['title'].to_s,
                                 detail: "its #{names.size} queried " \
                                         "#{names.size == 1 ? 'metric has' : 'metrics have'} " \
                                         'stopped reporting -- this dashboard renders blank')
          end
          found.sort_by(&:id)
        rescue Errno::ENOENT
          []
        end

        def dashboard_metrics(payload)
          queries = []
          collect_queries(payload['widgets'], queries)
          queries.flat_map { |q| query_metrics(q) }.uniq
        end

        # Widget queries hide at every depth and under several shapes; the one
        # thing they share is the key `q`.
        def collect_queries(node, out)
          case node
          when Hash
            node.each do |key, value|
              key.to_s == 'q' && value.is_a?(String) ? out << value : collect_queries(value, out)
            end
          when Array then node.each { |item| collect_queries(item, out) }
          end
        end

        # The metric is the dotted identifier immediately before the tag brace:
        #   avg(last_10m):avg:METRIC{tags} by {x} > 2
        #
        # A first version required whitespace before the aggregator and so
        # failed to parse 21 of 28 real queries, every one an ordinary query
        # alert. It reported them as carrying no metric, which would have read
        # as "nothing to check" instead of "the parser is wrong". The dot
        # requirement keeps a bare word from being mistaken for a metric.
        QUERY_METRIC = /:([a-z][\w.]*)\s*\{/i

        def query_metrics(query)
          query.to_s.scan(QUERY_METRIC).flatten.uniq.select { |name| name.include?('.') }
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
          found.concat(powerpack_references(capture, monitors, slos))
          found.concat(dashboard_link_references(capture))
          found.concat(composite_references(capture, monitors))
          found.concat(slo_monitor_references(capture, monitors))
          found.sort_by(&:id)
        rescue Errno::ENOENT
          []
        end

        # A POWERPACK's widgets can reference a monitor too, and the audit was
        # blind to them.
        #
        # A powerpack is a reusable widget group embedded into dashboards, so
        # one dead reference inside it is broken everywhere it is used, not
        # once. Found live: monitor 106953745 is referenced by two dashboards
        # AND two powerpacks. The audit reported half of that, which understates
        # both the blast radius and how long the monitor has been gone.
        #
        # Their widgets hang off attributes.group_widget rather than a top-level
        # `widgets` key, which is why walking dashboards did not reach them.
        def powerpack_references(capture, monitors, slos)
          return [] if monitors.empty? && slos.empty?

          found = []
          capture.each(:powerpacks) do |id, payload|
            name = payload.dig('attributes', 'name').to_s
            each_widget(payload.dig('attributes', 'group_widget', 'definition', 'widgets')) do |definition|
              found.concat(widget_references(definition, id, { 'title' => name }, monitors, slos))
            end
          end
          found
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
