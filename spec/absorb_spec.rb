# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'pangea/datadog/absorb'

Absorb = Pangea::Datadog::Absorb

RSpec.describe Absorb do
  # A monitor shaped like the ones a real estate returns: provider-flattened
  # options, a python-repr tag defect, and a field no Terraform models.
  let(:monitor_payload) do
    {
      'id' => 123,
      'name' => 'RabbitMQ free memory',
      'type' => 'query alert',
      'query' => 'avg(last_5m):avg:rabbitmq.node.mem_used{*} > 90',
      'message' => "{{#is_alert}}\n@slack-alerts\n{{/is_alert}}",
      'tags' => ["['integration: rabbitmq'", "'monitors_ver:1']"],
      'priority' => 2,
      'created_at' => 1_600_000_000,
      'creator' => { 'name' => 'someone' },
      'overall_state' => 'OK',
      'options' => {
        'thresholds' => { 'critical' => 90, 'warning' => 80 },
        'notify_no_data' => true,
        'renotify_interval' => 30,
        'silenced' => { '*' => nil },
        'restriction_query' => 'env:production'
      }
    }
  end

  let(:dashboard_payload) do
    {
      'id' => 'abc-def-ghi',
      'title' => 'Production Overview',
      'layout_type' => 'ordered',
      'url' => '/dashboard/abc-def-ghi',
      'author_handle' => 'someone@example.com',
      'tags' => ['team:infra'],
      'template_variables' => [{ 'name' => 'env', 'prefix' => 'env', 'default' => '*' }],
      'widgets' => [
        {
          'id' => 111,
          'definition' => {
            'type' => 'group',
            'widgets' => [{ 'id' => 222, 'definition' => { 'type' => 'timeseries' } }]
          }
        }
      ]
    }
  end

  let(:config_hash) do
    {
      'account' => 'testorg',
      'credentials' => { 'source' => 'files' },
      'provenance' => [
        { 'name' => 'terraform', 'disposition' => 'frozen', 'match' => { 'tag' => 'created_by:terraform' } },
        { 'name' => 'script', 'disposition' => 'adopt', 'match' => { 'tag_prefix' => '[' } },
        { 'name' => 'manual', 'disposition' => 'adopt', 'match' => { 'default' => true } }
      ],
      'retire' => {
        'title_patterns' => ["\\A.+'s Dashboard\\b", '(?i)\\b(test|poc)\\b'],
        'duplicate_content' => 'keep_first'
      },
      'grouping' => { 'monitors_by_tag' => 'integration' },
      'tag_repair' => { 'enabled' => false }
    }
  end

  def config(overrides = {})
    Absorb::Config.new(config_hash.merge(overrides))
  end

  def rules(overrides = {})
    Absorb::Rules.from(config(overrides).tap(&:validate!))
  end

  describe Absorb::Config do
    it 'accepts a well-formed config' do
      expect { config.validate! }.not_to raise_error
    end

    # The teeth. Ruby's YAML has no strict-decode mode, so this is hand-built,
    # and without it a typo'd key is silently ignored and the config lies.
    it 'rejects an unknown top-level key' do
      expect { Absorb::Config.new(config_hash.merge('grouping_' => {})).validate! }
        .to raise_error(Absorb::Config::Error, /unknown key\(s\): grouping_/)
    end

    it 'rejects an unknown nested key' do
      bad = config_hash.merge('retire' => { 'title_pattern' => [] })
      expect { Absorb::Config.new(bad).validate! }
        .to raise_error(Absorb::Config::Error, /config\.retire has unknown key\(s\): title_pattern/)
    end

    it 'rejects an unknown key inside a provenance rule' do
      bad = config_hash.merge('provenance' => [
                                { 'name' => 'x', 'disposition' => 'adopt', 'match' => { 'default' => true },
                                  'mtch' => {} }
                              ])
      expect { Absorb::Config.new(bad).validate! }
        .to raise_error(Absorb::Config::Error, /provenance\[0\] has unknown key\(s\): mtch/)
    end

    it 'requires an account' do
      expect { Absorb::Config.new(config_hash.reject { |k, _| k == 'account' }).validate! }
        .to raise_error(Absorb::Config::Error, /account is required/)
    end

    # Without a terminal rule, a monitor matching nothing is unclassified, and
    # unclassified silently means "not emitted".
    it 'requires a terminal default provenance rule' do
      bad = config_hash.merge('provenance' => [
                                { 'name' => 'tf', 'disposition' => 'frozen', 'match' => { 'tag' => 'a' } }
                              ])
      expect { Absorb::Config.new(bad).validate! }
        .to raise_error(Absorb::Config::Error, /terminal rule/)
    end

    it 'rejects an unknown disposition' do
      bad = config_hash.merge('provenance' => [
                                { 'name' => 'x', 'disposition' => 'delete', 'match' => { 'default' => true } }
                              ])
      expect { Absorb::Config.new(bad).validate! }
        .to raise_error(Absorb::Config::Error, /disposition must be one of/)
    end

    it 'rejects a duplicate provenance name' do
      bad = config_hash.merge('provenance' => [
                                { 'name' => 'x', 'disposition' => 'adopt', 'match' => { 'tag' => 'a' } },
                                { 'name' => 'x', 'disposition' => 'adopt', 'match' => { 'default' => true } }
                              ])
      expect { Absorb::Config.new(bad).validate! }
        .to raise_error(Absorb::Config::Error, /duplicate provenance name/)
    end

    it 'rejects an invalid retire regexp naming the index' do
      bad = config_hash.merge('retire' => { 'title_patterns' => ['valid', '([unclosed'] })
      expect { Absorb::Config.new(bad).validate! }
        .to raise_error(Absorb::Config::Error, /retire\.title_patterns\[1\]/)
    end

    it 'rejects an archetype with no widgets' do
      bad = config_hash.merge('archetypes' => [
                                { 'name' => 'a', 'engine' => 'timeseries_grid',
                                  'match' => { 'title' => 'x' }, 'widgets' => [] }
                              ])
      expect { Absorb::Config.new(bad).validate! }
        .to raise_error(Absorb::Config::Error, /widgets must be a non-empty list/)
    end

    it 'rejects a widget layout missing a dimension' do
      bad = config_hash.merge('archetypes' => [
                                { 'name' => 'a', 'engine' => 'timeseries_grid', 'match' => { 'title' => 'x' },
                                  'group_by' => 'g',
                                  'widgets' => [{ 'metric' => 'm', 'query' => 'q', 'legend' => 'vertical',
                                                  'layout' => { 'x' => 0, 'y' => 0 } }] }
                              ])
      expect { Absorb::Config.new(bad).validate! }
        .to raise_error(Absorb::Config::Error, /layout is missing width, height/)
    end

    # Braces are required: a bare hash at a call site goes to keywords in Ruby 3,
    # which leaves the positional arg empty.
    it 'defaults the credential source to sops' do
      expect(Absorb::Config.new({ 'account' => 'x' }).credential_source).to eq('sops')
    end

    # The secret path convention must match what the nix profiles declare, or
    # the deployer and the consumer drift apart.
    it 'derives fleet-convention secret paths from the account' do
      cfg = Absorb::Config.new({ 'account' => 'akeyless' })
      expect(cfg.api_key_secret).to eq('datadog/akeyless/api-key')
      expect(cfg.app_key_secret).to eq('datadog/akeyless/app-key')
    end

    it 'loads and validates both shipped configs' do
      root = File.expand_path('../config', __dir__)
      %w[akeyless.yaml example-other-org.yaml].each do |name|
        expect { Absorb::Config.load(File.join(root, name)) }.not_to raise_error
      end
    end
  end

  # The generality claim, tested rather than asserted.
  describe Absorb::Rules do
    it 'makes the minimum judgement with no config at all' do
      none = Absorb::Rules.none

      expect(none.retire_title?("Niv's Dashboard")).to be(false)
      expect(none.dedupe_identical?).to be(false)
      expect(none.archetype_for('anything')).to be_nil
      expect(none.group_for(monitor_payload)).to eq('unclassified')
      expect(none.provenance_of(monitor_payload)).to be_nil
    end

    it 'carries no organisation policy in code' do
      engine_source = File.read(File.expand_path('../lib/pangea/datadog/absorb/rules.rb', __dir__))
      expect(engine_source).not_to match(/akeyless|walmart|dbk|cvs/i)
    end

    it 'resolves provenance from config order' do
      tf = monitor_payload.merge('tags' => ['created_by:terraform'])

      expect(rules.provenance_of(tf)).to eq('terraform')
      expect(rules.frozen?(tf)).to be(true)
      expect(rules.provenance_of(monitor_payload)).to eq('script')
      expect(rules.adopt?(monitor_payload)).to be(true)
    end

    it 'repairs a python list repr and a space after the separator' do
      expect(rules.repair_tags(monitor_payload['tags']))
        .to eq(['integration:rabbitmq', 'monitors_ver:1'])
    end

    it 'leaves clean tags untouched' do
      clean = ['integration:kubernetes', 'created_by:terraform']
      expect(rules.repair_tags(clean)).to eq(clean)
    end

    it 'groups monitors by the configured tag' do
      expect(rules.group_for(monitor_payload)).to eq('rabbitmq')
      expect(rules.group_for('tags' => [])).to eq('unclassified')
    end

    # The regression that the state-match oracle caught: the emitted count moved
    # 274 -> 280 while every attribute still matched, because a case-insensitive
    # constant became a case-sensitive Regexp.new. Inline (?i) is the fix.
    it 'honours an inline case-insensitive flag in a retire pattern' do
      expect(rules.retire_title?('Akeyless GW - POC')).to be(true)
      expect(rules.retire_title?('Anomaly Dashboard - Test')).to be(true)
    end

    it 'does not retire on a pattern that omits the flag' do
      strict = rules('retire' => { 'title_patterns' => ['\\b(test|poc)\\b'] })
      expect(strict.retire_title?('Akeyless GW - POC')).to be(false)
    end
  end

  describe Absorb::Normalize do
    it 'lifts monitor options onto the provider attribute surface' do
      attrs = described_class.monitor(monitor_payload)

      expect(attrs[:monitor_thresholds]).to eq('critical' => 90, 'warning' => 80)
      expect(attrs[:notify_no_data]).to be(true)
      expect(attrs[:renotify_interval]).to eq(30)
    end

    it 'renders priority as the string the provider expects' do
      expect(described_class.monitor(monitor_payload)[:priority]).to eq('2')
    end

    it 'drops server-owned fields so they can never be authored' do
      attrs = described_class.monitor(monitor_payload)

      %i[id creator overall_state silenced].each { |k| expect(attrs).not_to have_key(k) }
    end

    it 'reports a provider-unmanageable option instead of silently losing it' do
      expect(described_class.monitor_unmapped(monitor_payload)[:unmanageable])
        .to include('restriction_query')
    end

    it 'reports nothing unmapped for a fully understood monitor' do
      expect(described_class.monitor_unmapped(monitor_payload)[:options]).to be_empty
    end

    it 'strips widget ids at every depth, including inside groups' do
      widgets = described_class.dashboard(dashboard_payload)[:widget]

      expect(widgets.first).not_to have_key('id')
      expect(widgets.first['definition']['widgets'].first).not_to have_key('id')
    end

    it 'maps the dashboard tabs construct onto the provider tab attribute' do
      payload = dashboard_payload.merge('tabs' => [{ 'title' => 'Nodes' }])

      expect(described_class.dashboard(payload)).to have_key(:tab)
      expect(described_class.dashboard_unmapped(payload)).to be_empty
    end

    it 'is stable across runs so a regenerated file produces no diff' do
      expect(described_class.monitor(monitor_payload)).to eq(described_class.monitor(monitor_payload))
    end
  end

  describe Absorb::Classify do
    it 'retires a dashboard matching a configured title pattern' do
      payload = dashboard_payload.merge('title' => "Niv's Dashboard")

      expect(described_class.dashboard_tier(payload, id: 'x', rules: rules))
        .to eq(described_class::TIER_RETIRE)
    end

    it 'retires a dashboard with no widgets' do
      payload = dashboard_payload.merge('widgets' => [])

      expect(described_class.dashboard_tier(payload, id: 'x', rules: rules))
        .to eq(described_class::TIER_RETIRE)
    end

    it 'keeps exactly one member of a set of identical dashboards' do
      fp = Absorb::Normalize.fingerprint(Absorb::Normalize.dashboard(dashboard_payload))
      twins = { fp => %w[aaa zzz] }

      expect(described_class.dashboard_tier(dashboard_payload, id: 'aaa', rules: rules, twins: twins))
        .not_to eq(described_class::TIER_RETIRE)
      expect(described_class.dashboard_tier(dashboard_payload, id: 'zzz', rules: rules, twins: twins))
        .to eq(described_class::TIER_RETIRE)
    end

    it 'keeps every duplicate when the config says keep_all' do
      keep_all = rules('retire' => { 'duplicate_content' => 'keep_all' })
      fp = Absorb::Normalize.fingerprint(Absorb::Normalize.dashboard(dashboard_payload))

      expect(described_class.dashboard_tier(dashboard_payload, id: 'zzz', rules: keep_all,
                                            twins: { fp => %w[aaa zzz] }))
        .not_to eq(described_class::TIER_RETIRE)
    end
  end

  describe Absorb::Engines::TimeseriesGrid do
    let(:recorder) do
      Class.new do
        attr_reader :last
        def datadog_dashboard_json(_name, attrs) = @last = attrs
      end.new
    end

    let(:widgets) do
      [{ 'metric' => 'gcp.cloudsql.database.cpu.utilization', 'query' => 'query1', 'legend' => 'vertical',
         'layout' => { 'x' => 0, 'y' => 0, 'width' => 6, 'height' => 5 } },
       { 'metric' => 'gcp.cloudsql.database.disk.utilization', 'query' => 'query3', 'legend' => 'horizontal',
         'layout' => { 'x' => 0, 'y' => 5, 'width' => 12, 'height' => 3 } }]
    end

    # The engine emits a JSON string; parse it back so the assertions read the
    # structure rather than the serialization.
    def build(**over)
      described_class.build(recorder, name: :d, title: 'T', scope: 'project_id:p',
                                      widgets: widgets, group_by: 'database_id', **over)
      JSON.parse(recorder.last[:dashboard])
    end

    it 'builds one widget per config row, in order' do
      built = build
      expect(built['widgets'].size).to eq(2)
      expect(built['widgets'][0].dig('definition', 'requests', 0, 'queries', 0, 'query'))
        .to eq('avg:gcp.cloudsql.database.cpu.utilization{project_id:p} by {database_id}')
    end

    it 'carries the per-row legend and layout from config' do
      built = build
      expect(built['widgets'][1].dig('definition', 'legend_layout')).to eq('horizontal')
      expect(built['widgets'][1]['layout']).to eq('x' => 0, 'y' => 5, 'width' => 12, 'height' => 3)
    end

    it 'names the formula after the row query so duplicates survive' do
      built = build
      expect(built['widgets'][1].dig('definition', 'requests', 0, 'formulas', 0, 'formula')).to eq('query3')
    end

    # Both parameters exist only because a real estate was irregular. Reproducing
    # the irregularity is the point; tidying it would be a separate change.
    it 'places the empty time key on exactly the listed widgets' do
      built = build(time_on: [1])
      expect(built['widgets'][0]['definition']).not_to have_key('time')
      expect(built['widgets'][1]['definition']).to have_key('time')
    end

    it 'applies a per-widget scope override verbatim' do
      built = build(scope_overrides: { 1 => 'project_id:p,!database_id:*x*' })
      expect(built['widgets'][1].dig('definition', 'requests', 0, 'queries', 0, 'query'))
        .to eq('avg:gcp.cloudsql.database.disk.utilization{project_id:p,!database_id:*x*} by {database_id}')
    end

    it 'mentions no organisation, metric or product in its source' do
      source = File.read(File.expand_path('../lib/pangea/datadog/absorb/engines/timeseries_grid.rb', __dir__))
      expect(source).not_to match(/gcp\.cloudsql|aws\.rds|akeyless|walmart/i)
    end
  end

  # The keyway standard: typed outcomes + JSON receipts + exit codes 0/1/2.
  describe Absorb::Receipt do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    # The distinction that matters: a FAIL means the tool ran correctly and the
    # answer is no; an ERROR means it could not answer at all. Collapsing them
    # would make a broken config look like a real state-match failure.
    it 'maps status to the keyway exit codes' do
      expect(described_class.pass(command: 'verify', target: 't').exit_code).to eq(0)
      expect(described_class.fail(command: 'verify', target: 't').exit_code).to eq(1)
      expect(described_class.error(command: 'verify', target: 't', message: 'x').exit_code).to eq(2)
    end

    it 'reports ok? only for a pass' do
      expect(described_class.pass(command: 'v', target: 't')).to be_ok
      expect(described_class.fail(command: 'v', target: 't')).not_to be_ok
      expect(described_class.error(command: 'v', target: 't', message: 'x')).not_to be_ok
    end

    it 'carries the envelope the keyway shape requires' do
      h = described_class.pass(command: 'verify', target: 'estate', findings: { 'checked' => 2 }).to_h

      expect(h['tool']).to eq('pangea-datadog-absorb')
      expect(h['command']).to eq('verify')
      expect(h['status']).to eq('pass')
      expect(h['target']).to eq('estate')
      expect(h['timestamp']).to match(/\A\d{8}T\d{6}Z\z/)
      expect(h['findings']).to eq('checked' => 2)
    end

    it 'omits the error key unless there was an error' do
      expect(described_class.pass(command: 'v', target: 't').to_h).not_to have_key('error')
      expect(described_class.error(command: 'v', target: 't', message: 'boom').to_h['error'])
        .to eq('boom')
    end

    it 'writes a parseable receipt named command-target-timestamp' do
      r = described_class.pass(command: 'verify', target: 'estate', findings: { 'checked' => 1 })
      path = r.write(@dir)

      expect(File.basename(path)).to match(/\Averify-estate-\d{8}T\d{6}Z\.json\z/)
      expect(JSON.parse(File.read(path))['status']).to eq('pass')
    end

    it 'writes nothing when no directory is configured' do
      expect(described_class.pass(command: 'v', target: 't').write(nil)).to be_nil
    end

    it 'sanitises a target that would not be a safe filename' do
      r = described_class.pass(command: 'verify', target: '/a/b c')
      expect(File.basename(r.write(@dir))).to match(/\Averify-a-b-c-/)
    end

    # The receipt must be derived from the gate's own result, so the JSON can
    # never disagree with the printed summary.
    it 'derives findings from a real verify result' do
      capture = Absorb::Capture.new(File.join(@dir, 'estate'))
      capture.prepare
      capture.write(:monitors, '123', monitor_payload)
      out = File.join(@dir, 'generated')
      imports  = Absorb::Emit.new(capture: capture, out_dir: out, rules: rules).run
      findings = Absorb::Verify.new(capture: capture, out_dir: out).run.findings

      # Derived from the emit rather than hardcoded: the point is that the
      # receipt agrees with the gate, not that a fixture has a given size.
      expect(findings['checked']).to eq(imports.size)
      expect(findings['matched']).to eq(imports.size)
      expect(findings['diffs']).to eq(0)
    end
  end

  # The roundtrip verb decides adoption readiness, so its pure logic is tested
  # here without touching terraform or Datadog. The terraform half is exercised
  # by running the verb against the live estate.
  describe Absorb::Roundtrip do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def capture_with(monitors: {}, dashboards: {})
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      monitors.each { |id, p| cap.write(:monitors, id, p) }
      dashboards.each { |id, p| cap.write(:dashboards, id, p) }
      cap
    end

    def roundtrip(cap) = described_class.new(capture: cap, provider_dir: '/x', rules: rules)

    it 'classifies an empty plan as no_changes' do
      rt = roundtrip(capture_with)
      out = rt.classify_plan(:monitors, '1', 'n', { ok: true, out: 'No changes. Your infrastructure matches.', err: '' })

      expect(out.status).to eq(:no_changes)
      expect(out).to be_clean
      expect(out.detail).to be_nil
    end

    it 'classifies a non-empty plan as drift and keeps the detail' do
      rt = roundtrip(capture_with)
      out = rt.classify_plan(:monitors, '1', 'n', { ok: true, out: "Plan: 0 to add, 1 to change, 0 to destroy.\n", err: '' })

      expect(out.status).to eq(:drift)
      expect(out).not_to be_clean
      expect(out.detail).to include('1 to change')
    end

    # A plan that ERRORS is not drift: the tool could not answer, versus
    # answering "they differ". Collapsing them would hide a broken config.
    it 'classifies a failed plan as plan_error, distinct from drift' do
      rt = roundtrip(capture_with)
      out = rt.classify_plan(:monitors, '1', 'n', { ok: false, out: '', err: 'Error: Conflicting configuration arguments' })

      expect(out.status).to eq(:plan_error)
      expect(out.detail).to include('Conflicting')
    end

    it 'carries the ignore_changes block on a monitor body' do
      rt = roundtrip(capture_with)
      body = rt.body_for(:monitors, monitor_payload)

      expect(body['lifecycle']).to eq([{ 'ignore_changes' => Absorb::Emit::MONITOR_UNROUNDTRIPPABLE.map(&:to_s) }])
      expect(body['name']).to eq('RabbitMQ free memory')
    end

    it 'builds a dashboard body as a single json string' do
      rt = roundtrip(capture_with)
      body = rt.body_for(:dashboards, dashboard_payload)

      expect(body.keys).to eq(['dashboard'])
      expect(JSON.parse(body['dashboard'])['title']).to eq('Production Overview')
    end

    it 'refuses a kind it has no body for' do
      rt = roundtrip(capture_with)
      expect { rt.body_for(:notakind, {}) }.to raise_error(Absorb::Roundtrip::Error, /no terraform body/)
    end

    # Planning the raw projection while the emitter ships the recorded one would
    # make the pass rate a claim about code nobody deploys.
    it 'plans the reconciled body the emitter would actually declare' do
      cap = capture_with(dashboards: { 'abc-def-ghi' => dashboard_payload })
      cap.write_normalized(:dashboards, 'abc-def-ghi',
                           { 'title' => 'T', 'layout_type' => 'ordered', 'widgets' => [] })

      body = roundtrip(cap).body_for(:dashboards, dashboard_payload, 'abc-def-ghi')

      expect(JSON.parse(body['dashboard'])['title']).to eq('T')
    end

    # The flaw this fixes: sampling the whole capture planned objects the
    # emitter never declares -- the monitors another IaC system owns, and the
    # retire-tier dashboards. The rate then answered a question nobody asked.
    it 'skips a monitor owned by another IaC system' do
      frozen = monitor_payload.merge('tags' => ['created_by:terraform'])
      cap = capture_with(monitors: { '1' => monitor_payload, '2' => frozen })
      spec = described_class::KINDS[:monitors]

      expect(roundtrip(cap).adoptable(:monitors, spec)).to eq(['1'])
    end

    it 'skips a retire-tier dashboard' do
      scratch = dashboard_payload.merge('title' => "Niv's Dashboard")
      cap = capture_with(dashboards: { 'keep' => dashboard_payload, 'drop' => scratch })
      spec = described_class::KINDS[:dashboards]

      expect(roundtrip(cap).adoptable(:dashboards, spec)).to eq(['keep'])
    end

    it 'plans every SLO and downtime, which have no tiering' do
      cap = capture_with
      cap.write(:slos, 's1', { 'name' => 'x' })
      expect(roundtrip(cap).adoptable(:slos, described_class::KINDS[:slos])).to eq(['s1'])
    end
  end

  describe 'the round trip' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def build_capture
      capture = Absorb::Capture.new(File.join(@dir, 'estate'))
      capture.prepare
      capture.write(:monitors, '123', monitor_payload)
      capture.write(:dashboards, 'abc-def-ghi', dashboard_payload)
      capture
    end

    def emit(capture, out = File.join(@dir, 'generated'))
      Absorb::Emit.new(capture: capture, out_dir: out, rules: rules).run
      out
    end

    it 'emits code that state-matches the capture' do
      capture = build_capture
      result  = Absorb::Verify.new(capture: capture, out_dir: emit(capture)).run

      expect(result.diffs).to be_empty
      expect(result.unmapped).to be_empty
      expect(result.checked).to eq(2)
      expect(result).to be_ok
    end

    it 'never emits a frozen monitor, so two writers cannot own one object' do
      capture = Absorb::Capture.new(File.join(@dir, 'estate'))
      capture.prepare
      capture.write(:monitors, '999', monitor_payload.merge('tags' => ['created_by:terraform']))
      imports = Absorb::Emit.new(capture: capture, out_dir: File.join(@dir, 'g'), rules: rules).run

      expect(imports).to be_empty
    end

    it 'reports the unmanageable option without failing the gate' do
      capture = build_capture
      result  = Absorb::Verify.new(capture: capture, out_dir: emit(capture)).run

      expect(result.unmanageable.flat_map { |u| u[:keys] }).to include('options.restriction_query')
      expect(result).to be_ok
    end

    # The gate is only worth running if it can fail.
    it 'fails when the emitted code no longer says what the estate says' do
      capture = build_capture
      out     = emit(capture)
      file    = Dir.glob(File.join(out, 'monitors_*.rb')).first
      File.write(file, File.read(file).sub('renotify_interval: 30', 'renotify_interval: 999'))

      result = Absorb::Verify.new(capture: capture, out_dir: out).run

      expect(result).not_to be_ok
      expect(result.diffs.map { |d| d[:attribute] }).to include('renotify_interval')
    end

    it 'fails when an emitted resource is never built' do
      capture = build_capture
      out     = emit(capture)
      imports = JSON.parse(File.read(File.join(out, 'imports.json')))
      imports['datadog_monitor.phantom'] = '999'
      File.write(File.join(out, 'imports.json'), JSON.generate(imports))

      result = Absorb::Verify.new(capture: capture, out_dir: out).run

      expect(result).not_to be_ok
      expect(result.diffs.map { |d| d[:attribute] }).to include('(emitted but never built)')
    end

    it 'refuses to let two group names collide into one module' do
      emitter = Absorb::Emit.new(capture: build_capture, out_dir: File.join(@dir, 'x'), rules: rules)
      emitter.send(:write_template, 'monitors_rabbitmq', []) { '' }

      expect { emitter.send(:write_template, 'monitors__rabbitmq', []) { '' } }
        .to raise_error(/claimed by both/)
    end

    it 'produces byte-identical output when run twice' do
      capture = build_capture
      first   = emit(capture)
      second  = emit(capture, File.join(@dir, 'generated2'))

      Dir.glob(File.join(first, '**', '*.rb')).each do |f|
        expect(File.read(f)).to eq(File.read(f.sub(first, second)))
      end
    end
  end

  # The provider-normalized sidecar, written by `reconcile`.
  #
  # It exists because the Datadog provider's read and plan normalizations
  # disagree for some dashboards: no transformation of the API payload can
  # produce a body that plans clean, only the provider's own post-import body
  # can. Recording it in the CAPTURE rather than the emitted code is what keeps
  # verify's contract code-vs-estate -- the provider's view simply becomes part
  # of the recorded estate.
  #
  # Every one of these must hold, or the sidecar is a silent behaviour change
  # rather than the opt-in lever it is meant to be.
  describe 'the reconcile sidecar' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    let(:provider_body) do
      { 'title' => 'Production Overview', 'layout_type' => 'ordered',
        'widgets' => [{ 'id' => 1, 'definition' => { 'type' => 'note', 'content' => 'from the provider' } }] }
    end

    def capture_with_sidecar(body: provider_body)
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      cap.write(:dashboards, 'abc-def-ghi', dashboard_payload)
      cap.write_normalized(:dashboards, 'abc-def-ghi', body) if body
      cap
    end

    it 'round trips a body through the capture' do
      cap = capture_with_sidecar

      expect(cap).to be_normalized(:dashboards, 'abc-def-ghi')
      expect(cap.normalized(:dashboards, 'abc-def-ghi')).to eq(provider_body)
    end

    it 'reports absent and returns nil when nothing was recorded' do
      cap = capture_with_sidecar(body: nil)

      expect(cap).not_to be_normalized(:dashboards, 'abc-def-ghi')
      expect(cap.normalized(:dashboards, 'abc-def-ghi')).to be_nil
    end

    # The sidecar lives beside the raw payload, never on top of it: the capture
    # stays a lossless record of what the API said.
    it 'never overwrites the raw API payload' do
      cap = capture_with_sidecar

      expect(cap.read(:dashboards, 'abc-def-ghi')).to eq(dashboard_payload)
    end

    it 'falls back to the API payload projection when no body was recorded' do
      expect(Absorb::Normalize.dashboard_json_for(dashboard_payload, nil))
        .to eq(Absorb::Normalize.dashboard_json(dashboard_payload))
    end

    it 'prefers the recorded body when there is one' do
      body = Absorb::Normalize.dashboard_json_for(dashboard_payload, provider_body)

      expect(JSON.parse(body[:dashboard])['widgets'][0]['definition']['content'])
        .to eq('from the provider')
    end

    # Same reason the raw projection is sorted: an unstable key order would make
    # every re-emit a spurious diff.
    it 'sorts the recorded body so emission stays deterministic' do
      shuffled = { 'widgets' => [], 'title' => 'T', 'layout_type' => 'ordered' }
      json = Absorb::Normalize.dashboard_json_for(dashboard_payload, shuffled)[:dashboard]

      expect(JSON.parse(json).keys).to eq(%w[layout_type title widgets])
    end

    it 'emits the recorded body and still state-matches the estate' do
      cap = capture_with_sidecar
      out = File.join(@dir, 'generated')
      Absorb::Emit.new(capture: cap, out_dir: out, rules: rules).run

      expect(File.read(Dir.glob(File.join(out, 'dashboards', '*.rb')).first))
        .to include('from the provider')
      expect(Absorb::Verify.new(capture: cap, out_dir: out).run).to be_ok
    end

    # The whole point of the sidecar being opt-in: with no recorded body the
    # default path must be bit-for-bit what it was before it existed.
    it 'leaves emission unchanged when nothing was recorded' do
      plain = capture_with_sidecar(body: nil)
      out   = File.join(@dir, 'plain')
      Absorb::Emit.new(capture: plain, out_dir: out, rules: rules).run

      recorded = capture_with_sidecar
      out2     = File.join(@dir, 'recorded')
      Absorb::Emit.new(capture: recorded, out_dir: out2, rules: rules).run

      expect(File.read(Dir.glob(File.join(out, 'dashboards', '*.rb')).first))
        .not_to eq(File.read(Dir.glob(File.join(out2, 'dashboards', '*.rb')).first))
    end
  end
end
