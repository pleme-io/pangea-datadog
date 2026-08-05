# frozen_string_literal: true

require 'json'
require 'yaml'
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

  # The generality claim, PROVEN rather than documented.
  #
  # config/example-other-org.yaml carries a header listing every dimension in
  # which it differs from akeyless.yaml. Until now nothing checked that any of
  # those differences reached the engine: both configs were loaded, validated,
  # and never driven. A config file that parses is not a proof of generality.
  #
  # This drives ONE capture through BOTH shipped configs and asserts the outputs
  # differ exactly as each config dictates. If the engine ever bakes in an
  # assumption about one organisation, a differential test is what notices.
  describe 'the same capture under both shipped configs' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def shipped(name)
      Absorb::Rules.from(Absorb::Config.load(
                           File.expand_path("../config/#{name}", __dir__)
                         ))
    end

    let(:akeyless) { shipped('akeyless.yaml') }
    let(:other) { shipped('example-other-org.yaml') }

    # tagged for BOTH conventions, so the difference is the config, not the data
    let(:shared_monitor) do
      monitor_payload.merge('tags' => ['integration:rabbitmq', 'service:api', 'owner:pulumi'])
    end

    it 'reads ownership from a different tag convention' do
      # akeyless matches on created_by:/tag-prefix conventions, so a monitor
      # tagged only owner:pulumi falls through to its terminal rule and is
      # adopted. The other org reads that same tag as another writer's mark.
      expect(akeyless.provenance_of(shared_monitor)).to eq('manual')
      expect(akeyless.adopt?(shared_monitor)).to be(true)

      expect(other.provenance_of(shared_monitor)).to eq('pulumi')
      expect(other.frozen?(shared_monitor)).to be(true)
      expect(other.adopt?(shared_monitor)).to be(false)
    end

    # `ignore` is a disposition akeyless does not use at all.
    it 'honours a disposition the other config does not have' do
      legacy = monitor_payload.merge('tags' => ['legacy/imported'])

      expect(other.provenance_of(legacy)).to eq('legacy-import')
      expect(other.adopt?(legacy)).to be(false)
      expect(other.frozen?(legacy)).to be(false)
    end

    it 'groups monitors by a different tag' do
      expect(akeyless.group_for(shared_monitor)).to eq('rabbitmq')
      expect(other.group_for(shared_monitor)).to eq('api')
    end

    it 'falls back to a different name when the grouping tag is absent' do
      untagged = { 'tags' => [] }

      expect(akeyless.group_for(untagged)).to eq('unclassified')
      expect(other.group_for(untagged)).to eq('unowned')
    end

    # Two different questions, and conflating them would be a real bug.
    # `repair_tags` is the pure repair, used to MATCH provenance so a corrupted
    # tag still classifies correctly -- that must happen under either config.
    # `repair_on_emit?` decides whether the repaired form is what gets written,
    # and akeyless deliberately leaves it off so the estate defect stays visible
    # in the generated code rather than being silently tidied away.
    it 'repairs tags for matching under either config' do
      broken = ["['integration: rabbitmq'", "'monitors_ver:1']"]
      repaired = ['integration:rabbitmq', 'monitors_ver:1']

      expect(other.repair_tags(broken)).to eq(repaired)
      expect(akeyless.repair_tags(broken)).to eq(repaired)
    end

    it 'writes the repaired form only where the config asks for it' do
      expect(other.repair_on_emit?).to be(true)
      expect(akeyless.repair_on_emit?).to be(false)
    end

    it 'leaves a corrupted tag corrupted in akeyless output, and fixes it in the other' do
      broken = monitor_payload.merge('id' => 2, 'tags' => ["['integration: rabbitmq'", "'x:1']"])
      capture = Absorb::Capture.new(File.join(@dir, 'repair'))
      capture.prepare
      capture.write(:monitors, '2', broken)

      Absorb::Emit.new(capture: capture, out_dir: File.join(@dir, 'ra'), rules: akeyless).run
      emitted = File.read(Dir[File.join(@dir, 'ra', 'monitors_*.rb')].first)

      expect(emitted).to include("[\'integration: rabbitmq\'")
    end

    it 'dedupes identical dashboards only where the config asks for it' do
      expect(akeyless.dedupe_identical?).to be(true)
      expect(other.dedupe_identical?).to be(false)
    end

    it 'retires on title only where patterns are configured' do
      expect(akeyless.retire_title?('Akeyless GW - POC')).to be(true)
      expect(other.retire_title?('Akeyless GW - POC')).to be(false)
    end

    it 'matches a different archetype family' do
      expect(other.archetype_for('billing RDS Pair')&.name).to eq('rds_pair')
      expect(akeyless.archetype_for('billing RDS Pair')).to be_nil
    end

    # The end-to-end difference: the same capture, emitted twice, lands in
    # differently-named files and adopts a different set.
    it 'emits a different result from the same capture' do
      capture = Absorb::Capture.new(File.join(@dir, 'estate'))
      capture.prepare
      capture.write(:monitors, '1', shared_monitor.merge('id' => 1))

      a = Absorb::Emit.new(capture: capture, out_dir: File.join(@dir, 'a'), rules: akeyless).run
      b = Absorb::Emit.new(capture: capture, out_dir: File.join(@dir, 'b'), rules: other).run

      # akeyless adopts it and files it under its integration tag
      expect(a.keys).to eq(['datadog_monitor.rabbitmq_free_memory_1'])
      expect(File).to exist(File.join(@dir, 'a', 'monitors_rabbitmq.rb'))

      # the other org treats pulumi as another writer and declares nothing
      expect(b).to be_empty
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

    # A sweep once reported 155/340 after the provider's nix store path was
    # garbage-collected mid-run. Every import after that point failed, and the
    # rate counted them as "not clean" -- presenting a harness failure as a
    # false regression across the whole estate.
    #
    # The tell is the failure MODE, not the count: a real body defect shows up
    # as a plan that DIVERGES, never as an import that cannot start.
    describe 'when the provider is unavailable' do
      it 'refuses to start rather than producing numbers' do
        rt = described_class.new(capture: capture_with, provider_dir: File.join(@dir, 'nope'),
                                 rules: rules)

        expect { rt.run(per_kind: 1, credentials: { api_key: 'k', app_key: 'a' }) }
          .to raise_error(Absorb::Roundtrip::Error, /no DataDog provider/)
      end

      it 'refuses a directory that exists but holds no datadog provider' do
        empty = File.join(@dir, 'empty-mirror')
        FileUtils.mkdir_p(empty)
        rt = described_class.new(capture: capture_with, provider_dir: empty, rules: rules)

        expect { rt.run(per_kind: 1, credentials: { api_key: 'k', app_key: 'a' }) }
          .to raise_error(Absorb::Roundtrip::Error, /no DataDog provider/)
      end

      # Mid-run loss: the pre-flight passed, then the provider vanished.
      it 'separates a vanished provider from a genuine import failure' do
        gone = 'Error: could not read package directory: open .terraform/providers/' \
               'registry.terraform.io/datadog/datadog/4.10.0/darwin_arm64: no such file'
        real = 'Error: monitor 123 not found'

        expect(gone).to match(Absorb::Roundtrip::PROVIDER_UNAVAILABLE)
        expect(real).not_to match(Absorb::Roundtrip::PROVIDER_UNAVAILABLE)
      end

      it 'also recognises the lock-file form of the same failure' do
        locked = 'provider registry.terraform.io/datadog/datadog: required by this ' \
                 'configuration but no version is selected'

        expect(locked).to match(Absorb::Roundtrip::PROVIDER_UNAVAILABLE)
      end
    end

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

    # The generated tree is COMMITTED to the delivery workspace, so `git diff`
    # is the drift detector. Any instability -- a hash order, a timestamp, an
    # unsorted glob -- turns every regeneration into a spurious diff and the
    # detector stops meaning anything.
    #
    # The narrower check above predates shards and sidecars and looks only at
    # .rb files. This spans every kind, includes a reconciled sidecar, and
    # compares EVERY emitted file including imports.json and the per-shard
    # slices.
    it 'is byte-identical across every emitted file, not just the ruby' do
      capture = Absorb::Capture.new(File.join(@dir, 'wide'))
      capture.prepare
      capture.write(:monitors, '123', monitor_payload)
      capture.write(:dashboards, 'abc-def-ghi', dashboard_payload)
      capture.write_normalized(:dashboards, 'abc-def-ghi', dashboard_payload)
      capture.write(:slos, 's1', { 'id' => 's1', 'name' => 'S', 'type' => 'metric',
                                   'thresholds' => [{ 'timeframe' => '7d', 'target' => 99 }] })
      capture.write(:teams, 't1', { 'id' => 't1', 'attributes' => { 'name' => 'T', 'handle' => 't' } })
      capture.write(:logs_metrics, 'm1', { 'id' => 'm1', 'attributes' => {
                      'filter' => { 'query' => 'q' }, 'compute' => { 'aggregation_type' => 'count' }
                    } })
      capture.write(:powerpacks, 'p1', { 'id' => 'p1', 'attributes' => { 'name' => 'P' } })
      capture.write_normalized(:powerpacks, 'p1', { 'name' => 'P', 'layout' => [{ 'x' => 0 }] })

      a = File.join(@dir, 'wide-a')
      b = File.join(@dir, 'wide-b')
      Absorb::Emit.new(capture: capture, out_dir: a, rules: rules).run
      Absorb::Emit.new(capture: capture, out_dir: b, rules: rules).run

      files = Dir.glob(File.join(a, '**', '*')).select { |f| File.file?(f) }
      expect(files.size).to be > 8
      files.each do |file|
        expect(File.read(file)).to eq(File.read(file.sub(a, b))), "#{File.basename(file)} differs"
      end
    end
  end

  # The logs configuration layer: 12 pipelines, 8 metrics, 1 index in the
  # measured estate.
  describe 'the logs configuration layer' do
    let(:custom_pipeline) do
      { 'id' => 'abc', 'type' => 'pipeline', 'name' => 'GeoIP Pipeline',
        'is_enabled' => false, 'is_read_only' => false,
        'filter' => { 'query' => '' },
        'processors' => [{ 'name' => 'geo', 'is_enabled' => true, 'sources' => ['@RemoteAddr'],
                           'target' => '@RemoteAddr.geoip',
                           'ip_processing_behavior' => 'do-nothing', 'type' => 'geo-ip-parser' }] }
    end

    let(:integration_pipeline) do
      custom_pipeline.merge('id' => 'def', 'name' => 'Nginx', 'is_read_only' => true, 'is_enabled' => true)
    end

    # Datadog ships its own pipelines into every account. The provider models
    # them as a different resource carrying only is_enabled, so emitting one as
    # a custom pipeline would recreate Datadog's own pipeline beside it.
    it 'splits read-only integration pipelines from custom ones' do
      expect(Absorb::Normalize.logs_pipeline_read_only?(integration_pipeline)).to be(true)
      expect(Absorb::Normalize.logs_pipeline_read_only?(custom_pipeline)).to be(false)
    end

    it 'carries nothing but the switch for an integration pipeline' do
      expect(Absorb::Normalize.logs_integration_pipeline(integration_pipeline))
        .to eq({ is_enabled: true })
    end

    it 'maps a processor type to its provider block name' do
      body = Absorb::Normalize.logs_custom_pipeline(custom_pipeline)

      expect(body[:processor].first.keys).to eq([:geo_ip_parser])
    end

    # Verified against the real provider schema: geo_ip_parser declares
    # is_enabled/name/sources/target and nothing else, so carrying the API's
    # ip_processing_behavior would emit a body terraform rejects.
    it 'drops a server-only processor field the provider does not model' do
      body = Absorb::Normalize.logs_custom_pipeline(custom_pipeline)

      expect(body[:processor].first[:geo_ip_parser].first).not_to have_key(:ip_processing_behavior)
      expect(body[:processor].first[:geo_ip_parser].first[:target]).to eq('@RemoteAddr.geoip')
    end

    # A silently dropped processor changes what a pipeline does to every log
    # flowing through it AND state-matches perfectly while doing it, because
    # verify only checks what the emitted code declares.
    it 'raises on a processor type it does not know' do
      expect { Absorb::Normalize.logs_processor({ 'type' => 'brand-new-thing' }) }
        .to raise_error(Absorb::Normalize::Error, /unknown log processor type/)
    end

    it 'lifts a logs metric out of its attributes envelope' do
      body = Absorb::Normalize.logs_metric(
        { 'id' => 'test.access.http.ok', 'type' => 'logs_metrics',
          'attributes' => { 'filter' => { 'query' => 'ACCESS' }, 'group_by' => [],
                            'compute' => { 'aggregation_type' => 'count' } } }
      )

      expect(body[:name]).to eq('test.access.http.ok')
      # HASH, not a one-element list: the typed datadog_logs_metric declares
      # filter and compute as Hash and group_by as a list, mirroring the
      # provider's own nesting. Emitting the terraform BLOCK shape type-errors
      # on the way into Pangea.
      expect(body[:filter]).to eq({ query: 'ACCESS' })
      expect(body[:compute]).to eq({ aggregation_type: 'count' })
      expect(body).not_to have_key(:group_by)
    end

    it 'renames the index fields the API and provider disagree about' do
      body = Absorb::Normalize.logs_index(
        { 'name' => 'all', 'filter' => { 'query' => '' }, 'num_retention_days' => 15,
          'daily_limit' => 200_000_000, 'is_rate_limited' => false,
          'num_flex_logs_retention_days' => 0, 'exclusion_filters' => [] }
      )

      expect(body[:retention_days]).to eq(15)
      expect(body[:flex_retention_days]).to eq(0)
      expect(body[:disable_daily_limit]).to be(false)
      expect(body).not_to have_key(:num_retention_days)
    end

    # The defect this class of fix exists for: `verify` cannot see it. Its
    # recording synth bypasses the typed resource layer entirely, so emitted
    # code can be type-INVALID and still pass the oracle 340/340. It surfaced
    # only when the emitted workspace was synthesized for real.
    it 'emits shapes the typed resource layer actually accepts' do
      metric = Absorb::Normalize.logs_metric(
        { 'id' => 'm', 'attributes' => { 'filter' => { 'query' => 'q' },
                                         'compute' => { 'aggregation_type' => 'count' },
                                         'group_by' => [{ 'path' => 'p', 'tag_name' => 't' }] } }
      )
      index = Absorb::Normalize.logs_index(
        { 'name' => 'all', 'filter' => { 'query' => '' }, 'num_retention_days' => 15,
          'daily_limit_reset' => { 'reset_time' => '14:00' } }
      )

      expect(metric[:filter]).to be_a(Hash)
      expect(metric[:compute]).to be_a(Hash)
      expect(metric[:group_by]).to be_a(Array)
      expect(index[:filter]).to be_a(Hash)
      expect(index[:daily_limit_reset]).to be_a(Hash)
    end

    it 'reports the index state the provider declines to model' do
      u = Absorb::Normalize.logs_unmapped('datadog_logs_index',
                                          { 'name' => 'all', 'is_rate_limited' => true })

      expect(u[:fields]).to be_empty
      expect(u[:unmanageable]).to eq(['is_rate_limited'])
    end

    it 'emits the two pipeline kinds as two different resources' do
      Dir.mktmpdir do |dir|
        cap = Absorb::Capture.new(File.join(dir, 'estate'))
        cap.prepare
        cap.write(:logs_pipelines, 'abc', custom_pipeline)
        cap.write(:logs_pipelines, 'def', integration_pipeline)
        imports = Absorb::Emit.new(capture: cap, out_dir: File.join(dir, 'g'), rules: rules).run

        expect(imports).to eq({ 'datadog_logs_custom_pipeline.geoip_pipeline_abc' => 'abc',
                                'datadog_logs_integration_pipeline.nginx_def' => 'def' })
      end
    end
  end

  # The delivery chart renders one InfrastructureTemplate per shard, each
  # carrying only ITS slice of the import hints. A shard that declares more
  # resources than it can import would plan a CREATE for the remainder, and
  # Datadog has no uniqueness constraint to turn that into a visible error --
  # it is a silent duplicate of a live object.
  describe 'shard entry points' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def emit_all
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      cap.write(:monitors, '123', monitor_payload)
      cap.write(:dashboards, 'abc-def-ghi', dashboard_payload)
      cap.write(:teams, 't1', { 'id' => 't1', 'attributes' => { 'name' => 'Infra', 'handle' => 'i' } })
      out = File.join(@dir, 'generated')
      [Absorb::Emit.new(capture: cap, out_dir: out, rules: rules).run, out]
    end

    it 'writes an entry point and an import slice per shard' do
      _imports, out = emit_all

      expect(File).to exist(File.join(out, 'shards', 'monitors.rb'))
      expect(File).to exist(File.join(out, 'shards', 'monitors.imports.json'))
    end

    # The invariant the whole shard design rests on.
    it 'partitions every address into exactly one shard' do
      imports, out = emit_all
      slices = Dir[File.join(out, 'shards', '*.imports.json')].map { |f| JSON.parse(File.read(f)) }
      addresses = slices.flat_map(&:keys)

      expect(addresses.sort).to eq(imports.keys.sort)
      expect(addresses.tally.select { |_, n| n > 1 }).to be_empty
    end

    # The dependency that motivated the split. An archetype dashboard is emitted
    # as a CALL to the absorb engine, so its file carries a `require` the plain
    # ones do not. The operator's compiler bundles whatever pangea-datadog its
    # flake pins, and a pin predating the engine cannot load that file -- so
    # keeping the two together would hold up every plain dashboard to ship five
    # archetype ones.
    it 'keeps archetype dashboards in a shard of their own' do
      cap = Absorb::Capture.new(File.join(@dir, 'arch'))
      cap.prepare
      cap.write(:dashboards, 'abc-def-ghi', dashboard_payload)
      cap.write(:dashboards, 'arch-1', dashboard_payload.merge(
                                         'id' => 'arch-1',
                                         'title' => "DBK Production Unified DB's (Estimation)"
                                       ))
      archetyped = rules('archetypes' => [
                           { 'name' => 'unified_dbs', 'engine' => 'timeseries_grid',
                             'group_by' => 'database_id',
                             'match' => { 'title' => "\\A(?<cluster>[\\w ]+) Unified DB's" },
                             'widgets' => [
                               { 'metric' => 'gcp.cloudsql.database.cpu.utilization',
                                 'query' => 'cpu', 'legend' => 'vertical',
                                 'layout' => { 'x' => 0, 'y' => 0, 'width' => 6, 'height' => 4 } }
                             ] }
                         ])
      out = File.join(@dir, 'archout')
      Absorb::Emit.new(capture: cap, out_dir: out, rules: archetyped).run

      plain = JSON.parse(File.read(File.join(out, 'shards', 'dashboards.imports.json')))
      arch  = JSON.parse(File.read(File.join(out, 'shards', 'dashboards-archetype.imports.json')))

      expect(plain.keys).to all(satisfy { |a| !arch.key?(a) })
      expect(arch.size).to eq(1)
      expect(File.read(File.join(out, 'shards', 'dashboards.rb')))
        .not_to include('absorb/engines')
    end

    # A shard name becomes part of an InfrastructureTemplate CR name, so the
    # chart's schema requires an RFC 1123 DNS label. `dashboards_archetype`
    # failed that outright while the other seven passed -- a mismatch that only
    # showed up when the two artifacts were actually put together.
    # A shard name lives in two namespaces with different rules, and deriving
    # both from one string is what broke: the chart needs a DNS label
    # (hyphens), Ruby needs a valid identifier (underscores).
    # `template :akeyless_datadog_dashboards-archetype do` is NOT a parse error
    # -- Ruby reads it as symbol-minus-method-call and dies at runtime, which is
    # why `ruby -c` reported "Syntax OK" on a file that could never run.
    it 'gives the template a valid ruby identifier even when the shard is hyphenated' do
      _imports, out = emit_all
      Dir[File.join(out, 'shards', '*.rb')].each do |file|
        header = File.read(file)[/^template :(\S+) do/, 1]

        expect(header).to match(/\A[a-z_][a-z0-9_]*\z/), "#{File.basename(file)} header: #{header}"
      end
    end

    it 'names every shard as a DNS label the chart will accept' do
      _imports, out = emit_all
      names = Dir[File.join(out, 'shards', '*.imports.json')]
              .map { |f| File.basename(f, '.imports.json') }

      expect(names).to all(match(/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/))
    end

    it 'refuses to emit a shard name the chart would reject' do
      emitter = Absorb::Emit.new(capture: Absorb::Capture.new(File.join(@dir, 'x')),
                                 out_dir: File.join(@dir, 'y'), rules: rules)
      emitter.instance_variable_set(:@shards, { 'bad_name' => { files: [], modules: [] } })

      expect { emitter.send(:write_shards, {}) }.to raise_error(/not a DNS label/)
    end

    # The chart renders nothing without shards[].importHints, and a missing hint
    # is a silent duplicate of a live object rather than an error. Emit knows
    # the partition, so hand-assembly is the one mistake worth designing out.
    it 'emits a values file carrying every hint, partitioned by shard' do
      imports, out = emit_all
      values = YAML.safe_load(File.read(File.join(out, 'values.yaml')))
      hints = values.fetch('shards').flat_map { |s| s.fetch('importHints').keys }

      expect(hints.sort).to eq(imports.keys.sort)
      expect(values['shards'].map { |s| s['name'] }).to all(match(/\A[a-z0-9-]+\z/))
    end

    # The chart FAILS when credentials.secretName is unset, deliberately. A
    # generated placeholder would turn that refusal into a silent default and
    # send every RPC to the pod's ambient credential chain.
    it 'leaves the credential name out of the generated values' do
      _imports, out = emit_all
      values = YAML.safe_load(File.read(File.join(out, 'values.yaml')))

      expect(values).not_to have_key('credentials')
    end

    it 'gives each shard a template of its own name' do
      _imports, out = emit_all

      expect(File.read(File.join(out, 'shards', 'monitors.rb')))
        .to include('template :akeyless_datadog_monitors do')
    end

    # verify must not load them: they are entry points, not declarations, and
    # loading one would both fail and double-count what it re-declares.
    it 'keeps the entry points out of the oracle' do
      _imports, out = emit_all

      expect(Absorb::Verify.new(capture: Absorb::Capture.new(File.join(@dir, 'estate')),
                                out_dir: out).run).to be_ok
    end
  end

  # Adoption turned out to be a correctness audit as a side effect: terraform
  # refused to plan three monitors, the refusal traced to Datadog's own
  # validator, and the validator named the reason. This runs the same check over
  # the whole capture instead of the ones that happened to block a plan.
  describe Absorb::Audit do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def capture_with(monitors: {}, slos: {})
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      slos.each { |id, payload| cap.write(:slos, id, payload) }
      monitors.each { |id, payload| cap.write(:monitors, id, payload) }
      cap
    end

    def slo(id, *timeframes)
      { 'id' => id, 'name' => 'S', 'thresholds' => timeframes.map { |t| { 'timeframe' => t } } }
    end

    def slo_alert(id, slo_id, timeframe)
      { 'id' => id, 'name' => "alert #{id}", 'type' => 'slo alert',
        'query' => %(error_budget("#{slo_id}").over("#{timeframe}") > 80) }
    end

    it 'reports an SLO alert asking for a timeframe its SLO does not have' do
      cap = capture_with(slos: { 's' => slo('s', '7d') },
                         monitors: { '1' => slo_alert(1, 's', '30d') })
      result = described_class.run(cap)

      expect(result).not_to be_ok
      expect(result.broken.map(&:id)).to eq(['1'])
      expect(result.broken.first.detail).to include('asks for 30d').and include('has 7d')
    end

    it 'passes an SLO alert whose timeframe the SLO carries' do
      cap = capture_with(slos: { 's' => slo('s', '7d', '30d') },
                         monitors: { '1' => slo_alert(1, 's', '30d') })

      expect(described_class.run(cap)).to be_ok
    end

    # Absence of evidence is not evidence of a defect: an SLO outside the
    # capture cannot be checked, and guessing would produce false alarms.
    it 'says nothing about an SLO it has not captured' do
      cap = capture_with(monitors: { '1' => slo_alert(1, 'missing', '30d') })

      expect(described_class.run(cap)).to be_ok
    end

    # The third known defect, and the reason it was added: the audit found 2 of
    # the 3 monitors terraform had independently refused. An audit that finds
    # two thirds of the known defects gives false confidence.
    it 'reports a service check with no grouping' do
      cap = capture_with(monitors: { '1' => {
                           'id' => 1, 'name' => 'ntp', 'type' => 'service check',
                           'query' => '"ntp.in_sync".over("*").last(2).count_by_status()'
                         } })
      result = described_class.run(cap)

      expect(result).not_to be_ok
      expect(result.broken.first.detail).to include('no grouping')
    end

    it 'passes a service check that carries one' do
      cap = capture_with(monitors: { '1' => {
                           'id' => 1, 'name' => 'ok', 'type' => 'service check',
                           'query' => '"aws.status".over("*").by("region").last(2).count_by_status()'
                         } })

      expect(described_class.run(cap)).to be_ok
    end

    # The grouping rule is specific to service checks; applying it to a metric
    # alert would flag most of the estate.
    it 'does not demand a grouping from a metric alert' do
      cap = capture_with(monitors: { '1' => {
                           'id' => 1, 'name' => 'metric', 'type' => 'query alert',
                           'query' => 'avg(last_5m):avg:system.cpu.user{*} > 90'
                         } })

      expect(described_class.run(cap)).to be_ok
    end

    # Defects are collected, not first-match: one monitor can carry two, and
    # adding a class must not silently displace another.
    it 'reports every defect a single monitor carries' do
      cap = capture_with(slos: { 's' => slo('s', '7d') },
                         monitors: { '1' => {
                           'id' => 1, 'name' => 'both', 'type' => 'service check',
                           'query' => %(error_budget("s").over("30d") > 80)
                         } })

      expect(described_class.run(cap).broken.size).to eq(2)
    end

    # A class terraform structurally CANNOT catch. The dashboard plans perfectly
    # clean -- the reference is just a number inside the widget JSON and the
    # provider has no idea the thing it names was deleted. Found live: two
    # dashboards still pointing at monitor 106953745, which returns 404.
    describe 'dangling references' do
      def dash(id, alert_id)
        { 'id' => id, 'title' => "board #{id}",
          'widgets' => [{ 'definition' => { 'type' => 'alert_graph',
                                            'alert_id' => alert_id.to_s } }] }
      end

      it 'reports a widget pointing at a monitor that is not in the estate' do
        cap = capture_with(monitors: { '1' => { 'id' => 1, 'name' => 'live' } })
        cap.write(:dashboards, 'd1', dash('d1', 999))
        result = described_class.run(cap)

        expect(result).not_to be_ok
        expect(result.dangling.first.detail).to include('999')
      end

      it 'passes a widget pointing at a monitor that exists' do
        cap = capture_with(monitors: { '1' => { 'id' => 1, 'name' => 'live' } })
        cap.write(:dashboards, 'd1', dash('d1', 1))

        expect(described_class.run(cap)).to be_ok
      end

      # Without this guard, `--kinds dashboards` would report EVERY reference as
      # dangling -- a flood of false defects from a capture that simply never
      # fetched the monitors.
      it 'checks nothing when no monitors were captured at all' do
        cap = capture_with
        cap.write(:dashboards, 'd1', dash('d1', 999))

        expect(described_class.run(cap)).to be_ok
      end

      it 'finds a reference nested inside a group widget' do
        cap = capture_with(monitors: { '1' => { 'id' => 1, 'name' => 'live' } })
        cap.write(:dashboards, 'd1', {
                    'id' => 'd1', 'title' => 'grouped',
                    'widgets' => [{ 'definition' => {
                      'type' => 'group',
                      'widgets' => [{ 'definition' => { 'type' => 'alert_graph',
                                                        'alert_id' => '999' } }]
                    } }]
                  })

        expect(described_class.run(cap).dangling.size).to eq(1)
      end

      # A composite names its constituents by id. One being deleted leaves an
      # alert that cannot resolve. The estate has 4 composites over 20
      # references, all intact -- so the estate proves no false positives and
      # these specs prove the check actually fires.
      it 'reports a composite naming a monitor that is gone' do
        cap = capture_with(monitors: {
                             '1' => { 'id' => 1, 'name' => 'live' },
                             '2' => { 'id' => 2, 'name' => 'comp', 'type' => 'composite',
                                      'query' => '1 && 999999' }
                           })

        expect(described_class.run(cap).dangling.first.detail).to include('999999')
      end

      it 'passes a composite whose constituents all exist' do
        cap = capture_with(monitors: {
                             '111111' => { 'id' => 111_111, 'name' => 'a' },
                             '222222' => { 'id' => 222_222, 'name' => 'b' },
                             '3' => { 'id' => 3, 'name' => 'comp', 'type' => 'composite',
                                      'query' => '111111 && 222222' }
                           })

        expect(described_class.run(cap)).to be_ok
      end

      # The id-shaped-number scan is bounded to composites on purpose: a metric
      # alert's threshold can be a large number and would otherwise read as a
      # monitor id.
      it 'does not scan a metric alert for monitor ids' do
        cap = capture_with(monitors: { '1' => {
                             'id' => 1, 'name' => 'metric', 'type' => 'query alert',
                             'query' => 'avg(last_5m):avg:x{*} > 9999999'
                           } })

        expect(described_class.run(cap)).to be_ok
      end

      # A monitor-based SLO losing a monitor does not break loudly -- it keeps
      # reporting, on less than it claims.
      it 'reports a monitor-based SLO naming a monitor that is gone' do
        cap = capture_with(monitors: { '1' => { 'id' => 1, 'name' => 'live' } },
                           slos: { 's' => { 'id' => 's', 'name' => 'uptime', 'type' => 'monitor',
                                            'monitor_ids' => [1, 999_999], 'thresholds' => [] } })

        expect(described_class.run(cap).dangling.first.detail).to include('999999')
      end

      it 'reports an SLO widget naming an SLO that is gone' do
        cap = capture_with(slos: { 's' => slo('s', '7d') },
                           monitors: { '1' => { 'id' => 1, 'name' => 'live' } })
        cap.write(:dashboards, 'd1', {
                    'id' => 'd1', 'title' => 'slo board',
                    'widgets' => [{ 'definition' => { 'type' => 'slo', 'slo_id' => 'gone' } }]
                  })

        expect(described_class.run(cap).dangling.first.detail).to include('gone')
      end
    end

    # THE distinction. Getting this wrong makes the audit cry wolf on every
    # healthy ephemeral monitor, and then the real defects get ignored with it.
    it 'does NOT fail the gate on a monitor that is merely silent' do
      cap = capture_with(monitors: { '1' => {
                           'id' => 1, 'name' => 'Pod Crashloop', 'query' => 'x',
                           'overall_state' => 'No Data', 'message' => 'ping @slack-team',
                           'overall_state_modified' => '2024-01-12T00:00:00+00:00'
                         } })
      result = described_class.run(cap)

      expect(result).to be_ok
      expect(result.silent.size).to eq(1)
    end

    # A silence nobody is told about is the one worth surfacing; a monitor with
    # no audience is not misleading anyone.
    it 'ignores a silent monitor that notifies nobody' do
      cap = capture_with(monitors: { '1' => {
                           'id' => 1, 'name' => 'unwatched', 'overall_state' => 'No Data',
                           'message' => 'no targets here',
                           'overall_state_modified' => '2024-01-12T00:00:00+00:00'
                         } })

      expect(described_class.run(cap).silent).to be_empty
    end

    # A cluster is the signal: five monitors going No Data on one day is an
    # infrastructure event, not five coincidences.
    it 'clusters silences that began on the same day, and ignores singletons' do
      monitors = {}
      3.times do |i|
        monitors[i.to_s] = { 'id' => i, 'name' => "azr #{i}", 'overall_state' => 'No Data',
                             'message' => '@slack-x',
                             'overall_state_modified' => '2024-01-12T00:00:00+00:00' }
      end
      monitors['9'] = { 'id' => 9, 'name' => 'lone', 'overall_state' => 'No Data',
                        'message' => '@slack-x',
                        'overall_state_modified' => '2025-06-01T00:00:00+00:00' }
      result = described_class.run(capture_with(monitors: monitors))

      expect(result.clusters.keys).to eq(['2024-01-12'])
      expect(result.clusters['2024-01-12'].size).to eq(3)
      expect(result.silent.size).to eq(4)
    end

    it 'records how long a silence has run' do
      cap = capture_with(monitors: { '1' => {
                           'id' => 1, 'name' => 'old', 'overall_state' => 'No Data',
                           'message' => '@slack-x',
                           'overall_state_modified' => '2024-01-12T00:00:00+00:00'
                         } })
      result = described_class.run(cap, today: Date.new(2026, 8, 5))

      expect(result.silent.first[:days]).to eq(936)
    end
  end

  # A capture that was never reconciled still HOLDS its powerpacks; emit just
  # cannot declare them. verify then checks only what emit declared, everything
  # matches, and the gate goes green while live objects are unmanaged -- the
  # same "nothing to check reads as everything is fine" failure already fixed
  # for an empty capture, in partial form.
  describe 'coverage gaps' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def capture_with_powerpack(reconciled:)
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      cap.write(:monitors, '123', monitor_payload)
      cap.write(:powerpacks, 'p1', { 'id' => 'p1', 'attributes' => { 'name' => 'Net' } })
      cap.write_normalized(:powerpacks, 'p1', { 'name' => 'Net' }) if reconciled
      cap
    end

    it 'fails when a captured powerpack was never reconciled' do
      cap = capture_with_powerpack(reconciled: false)
      out = File.join(@dir, 'g')
      Absorb::Emit.new(capture: cap, out_dir: out, rules: rules).run
      result = Absorb::Verify.new(capture: cap, out_dir: out).run

      expect(result).not_to be_ok
      expect(result.uncovered.size).to eq(1)
      expect(result.uncovered.first[:reason]).to include('reconcile')
    end

    it 'passes once that powerpack has a body' do
      cap = capture_with_powerpack(reconciled: true)
      out = File.join(@dir, 'g')
      Absorb::Emit.new(capture: cap, out_dir: out, rules: rules).run
      result = Absorb::Verify.new(capture: cap, out_dir: out).run

      expect(result).to be_ok
      expect(result.uncovered).to be_empty
    end

    # The line this must not cross. A Datadog-managed role, an APM filter the
    # provider rejects, a retire-tier dashboard -- all correct exclusions. A
    # gate that cried wolf about decisions it was told to make would be turned
    # off, and the real gaps would go with it.
    it 'stays silent about deliberate exclusions' do
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      cap.write(:monitors, '123', monitor_payload)
      cap.write(:roles, 'r1', { 'id' => 'r1', 'attributes' => { 'name' => 'Admin', 'managed' => true } })
      cap.write(:apm_retention_filters, 'f1', {
                  'id' => 'f1', 'attributes' => { 'name' => 'Default', 'enabled' => true,
                                                  'filter_type' => 'spans-errors-sampling-processor',
                                                  'rate' => 1 }
                })
      out = File.join(@dir, 'g')
      Absorb::Emit.new(capture: cap, out_dir: out, rules: rules).run

      expect(Absorb::Verify.new(capture: cap, out_dir: out).run).to be_ok
    end

    it 'carries the gap into the receipt, not just the printed summary' do
      cap = capture_with_powerpack(reconciled: false)
      out = File.join(@dir, 'g')
      Absorb::Emit.new(capture: cap, out_dir: out, rules: rules).run
      findings = Absorb::Verify.new(capture: cap, out_dir: out).run.findings

      expect(findings['uncovered']).to eq(1)
      expect(findings['uncoveredKinds'].first['kind']).to eq('powerpacks')
    end
  end

  # classify is the verb someone runs FIRST to see what adoption touches, and it
  # reported only monitors and dashboards while the estate held nine captured
  # kinds. That understated the scope and hid the deliberate exclusions -- the
  # part an approver most needs to see, because a skip nobody can see reads as
  # an oversight.
  describe 'the classify accounting' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def wide_capture
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      cap.write(:monitors, '123', monitor_payload)
      cap.write(:monitors, '999', monitor_payload.merge('id' => 999,
                                                        'tags' => ['created_by:terraform']))
      cap.write(:dashboards, 'abc-def-ghi', dashboard_payload)
      cap.write(:slos, 's1', { 'id' => 's1', 'name' => 'S', 'type' => 'metric',
                               'thresholds' => [{ 'timeframe' => '7d', 'target' => 99 }] })
      cap.write(:teams, 't1', { 'id' => 't1', 'attributes' => { 'name' => 'T', 'handle' => 't' } })
      cap.write(:roles, 'r1', { 'id' => 'r1', 'attributes' => { 'name' => 'Managed', 'managed' => true } })
      cap.write(:roles, 'r2', { 'id' => 'r2', 'attributes' => { 'name' => 'Ours' } })
      cap.write(:logs_pipelines, 'p1', { 'id' => 'p1', 'name' => 'Custom', 'is_read_only' => false,
                                         'filter' => { 'query' => '' }, 'processors' => [] })
      cap.write(:logs_pipelines, 'p2', { 'id' => 'p2', 'name' => 'Nginx', 'is_read_only' => true,
                                         'filter' => { 'query' => '' }, 'processors' => [] })
      cap
    end

    it 'accounts for kinds beyond monitors and dashboards' do
      wide_capture
      report = Absorb.classify(root: File.join(@dir, 'estate'))

      expect(report[:other_kinds].keys).to include(:slos, :teams, :roles, :logs_pipelines)
    end

    it 'shows WHY something is skipped, not just that it was' do
      wide_capture
      other = Absorb.classify(root: File.join(@dir, 'estate'))[:other_kinds]

      expect(other[:roles]).to eq({ captured: 2, emitted: 1, skipped_datadog_managed: 1 })
      expect(other[:logs_pipelines])
        .to eq({ captured: 2, emitted: 2, custom: 1, datadog_integration: 1 })
    end

    it 'says nothing about a kind the capture does not hold' do
      wide_capture
      other = Absorb.classify(root: File.join(@dir, 'estate'))[:other_kinds]

      expect(other).not_to have_key(:powerpacks)
      expect(other).not_to have_key(:downtimes)
    end

    # THE INVARIANT. The accounting must equal what emit actually produces, or
    # it is a story about the estate rather than a report on it.
    #
    # Both sides must read the SAME config: classify with no rules calls every
    # monitor unclassified-and-adoptable, while emit with rules freezes the
    # terraform-owned one. That is not a defect in either -- it is one question
    # asked two ways, and the first version of this spec asked it two ways.
    it 'reconciles exactly with what emit declares' do
      capture = wide_capture
      config_path = File.join(@dir, 'rules.yaml')
      File.write(config_path, YAML.dump(config_hash))
      shared = Absorb::Rules.from(Absorb::Config.load(config_path))

      imports = Absorb::Emit.new(capture: capture, out_dir: File.join(@dir, 'g'), rules: shared).run
      report = Absorb.classify(root: File.join(@dir, 'estate'), config_path: config_path)

      adoptable_monitors = report[:monitors].reject { |name, _| name == 'terraform' }.values.sum
      dashboards = report[:dashboards].reject { |tier, _| tier == Absorb::Classify::TIER_RETIRE }
                                      .values.sum
      others = report[:other_kinds].values.sum { |v| v[:emitted] }

      expect(adoptable_monitors + dashboards + others).to eq(imports.size)
    end
  end

  # The oracle as one command. Three hand-run steps whose result had to be read
  # off stdout are not a gate anybody else can run.
  describe 'the gate verb' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def build_capture
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      cap.write(:monitors, '123', monitor_payload)
      cap.write(:dashboards, 'abc-def-ghi', dashboard_payload)
      cap
    end

    it 'emits and verifies in one call' do
      build_capture
      result = Absorb.gate(root: File.join(@dir, 'estate'))

      expect(result).to be_ok
      expect(result.checked).to eq(2)
    end

    # A gate that leaves its output behind is a gate that can verify its own
    # debris on the next run.
    it 'leaves nothing behind when it emits to a temp directory' do
      build_capture
      before = Dir.children(@dir).sort
      Absorb.gate(root: File.join(@dir, 'estate'))

      expect(Dir.children(@dir).sort).to eq(before)
    end

    it 'keeps the output when an explicit directory is asked for' do
      build_capture
      out = File.join(@dir, 'kept')
      Absorb.gate(root: File.join(@dir, 'estate'), out_dir: out)

      expect(File).to exist(File.join(out, 'imports.json'))
    end

    # The whole point. A stale sidecar is the drift the gate exists to catch,
    # and it must survive the emit-fresh-every-time design -- emit and verify
    # both read the same capture, so only a real inconsistency inside that
    # capture can fail it.
    it 'fails when the capture contains a stale sidecar' do
      cap = build_capture
      cap.write_normalized(:dashboards, 'abc-def-ghi',
                           { 'title' => 'Something Else', 'widgets' => [] })

      result = Absorb.gate(root: File.join(@dir, 'estate'))

      expect(result).not_to be_ok
      expect(result.diffs.map { |d| d[:attribute] }.join).to include('stale sidecar')
    end

    # The worst failure a gate can have. An absent capture makes emit produce
    # nothing, verify check nothing, and the whole thing report PASS -- so a CI
    # run whose capture step silently failed would go green. Nothing to check is
    # "could not answer", never "the answer is yes".
    it 'refuses an absent capture rather than passing on nothing' do
      expect { Absorb.gate(root: File.join(@dir, 'nope')) }
        .to raise_error(Absorb::GateError, /no capture/)
    end

    it 'refuses a capture directory that holds no objects' do
      empty = File.join(@dir, 'empty')
      Absorb::Capture.new(empty).prepare

      expect { Absorb.gate(root: empty) }
        .to raise_error(Absorb::GateError, /holds no objects/)
    end

    it 'does not mistake a capture holding only one kind for an empty one' do
      cap = Absorb::Capture.new(File.join(@dir, 'onekind'))
      cap.prepare
      cap.write(:logs_metrics, 'm', { 'id' => 'm', 'attributes' => {} })

      expect(cap).not_to be_empty
    end

    it 'reports the same numbers to the receipt that it prints' do
      build_capture
      result = Absorb.gate(root: File.join(@dir, 'estate'))

      expect(result.findings['checked']).to eq(2)
      expect(result.findings['diffs']).to eq(0)
    end
  end

  # A reconciled object has a hole in the gate: emit ships the sidecar AND
  # verify derives its expectation from the sidecar, so the two agree by
  # construction. The failure that hides is STALENESS, and these invariants are
  # what closes it.
  #
  # Found a real one on first run against the live estate: a dashboard whose
  # capture reported 48 widgets and whose sidecar reported 34, with disjoint
  # titles -- two reads of the same object taken either side of an edit.
  describe 'sidecar fidelity' do
    let(:live) do
      { 'title' => 'Prod', 'template_variables' => [{ 'name' => 'env' }],
        'widgets' => [{ 'definition' => { 'title' => 'Outer', 'type' => 'group',
                                          'widgets' => [{ 'definition' => { 'title' => 'Inner' } }] } }] }
    end

    def fidelity(sidecar, kind: 'datadog_dashboard_json', payload: live)
      Absorb::Normalize.sidecar_fidelity(kind, payload, sidecar)
    end

    it 'passes when both reads describe the same object' do
      expect(fidelity(live)).to be_empty
    end

    it 'says nothing when there is no sidecar to be stale' do
      expect(fidelity(nil)).to be_empty
    end

    it 'ignores a kind that has no sidecar' do
      expect(fidelity(live, kind: 'datadog_monitor')).to be_empty
    end

    it 'catches a renamed dashboard' do
      expect(fidelity(live.merge('title' => 'Staging'))).to eq(['title'])
    end

    # Groups nest, so a flat count would miss an edit made inside one.
    it 'catches a widget removed from inside a group' do
      flattened = { 'title' => 'Prod', 'template_variables' => [{ 'name' => 'env' }],
                    'widgets' => [{ 'definition' => { 'title' => 'Outer', 'type' => 'group',
                                                      'widgets' => [] } }] }

      expect(fidelity(flattened)).to eq(%w[widget_count widget_titles])
    end

    it 'catches a retitled widget even when the count is unchanged' do
      renamed = Marshal.load(Marshal.dump(live))
      renamed['widgets'][0]['definition']['widgets'][0]['definition']['title'] = 'Changed'

      expect(fidelity(renamed)).to eq(['widget_titles'])
    end

    it 'catches a dropped template variable' do
      expect(fidelity(live.merge('template_variables' => []))).to eq(['template_variables'])
    end

    # The provider's powerpack state is a FLAT widget list -- the API's group
    # wrapper IS the powerpack -- so counting both recursively would compare a
    # flat list against a nested one and fail on every powerpack.
    describe 'powerpacks' do
      let(:pack) do
        { 'attributes' => { 'name' => 'Network', 'tags' => ['tag:akeyless'],
                            'group_widget' => { 'definition' => {
                              'widgets' => [{ 'definition' => { 'title' => 'a' } },
                                            { 'definition' => { 'title' => 'b' } }]
                            } } } }
      end

      def pp_fidelity(sidecar)
        Absorb::Normalize.sidecar_fidelity('datadog_powerpack', pack, sidecar)
      end

      it 'compares the flat provider list against the nested API group' do
        expect(pp_fidelity({ 'name' => 'Network', 'tags' => ['tag:akeyless'],
                             'widget' => [{ 'q' => 1 }, { 'q' => 2 }] })).to be_empty
      end

      it 'catches a widget added since the sidecar was recorded' do
        expect(pp_fidelity({ 'name' => 'Network', 'tags' => ['tag:akeyless'],
                             'widget' => [{ 'q' => 1 }] })).to eq(['widget_count'])
      end

      it 'catches a retagged powerpack' do
        expect(pp_fidelity({ 'name' => 'Network', 'tags' => [],
                             'widget' => [{ 'q' => 1 }, { 'q' => 2 }] })).to eq(['tags'])
      end
    end

    # Detection without repair leaves the operator stuck: verify says "stale"
    # and nothing can clear it except a hand-edit. reconcile closes that loop.
    describe 'repair' do
      around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

      def roundtrip_for(cap)
        Absorb::Roundtrip.new(capture: cap, provider_dir: '/x', rules: rules)
      end

      def capture_with(sidecar)
        cap = Absorb::Capture.new(File.join(@dir, 'estate'))
        cap.prepare
        cap.write(:dashboards, 'abc-def-ghi', dashboard_payload)
        cap.write_normalized(:dashboards, 'abc-def-ghi', sidecar)
        cap
      end

      # The critical case. A stale body can still plan clean -- if the live
      # object drifted and drifted back, or if the drift is in a field the plan
      # tolerates -- so trusting the pre-check would leave the stale sidecar in
      # place forever.
      it 'refreshes a stale sidecar even when the stale body plans clean' do
        cap = capture_with({ 'title' => 'Something Else', 'widgets' => [] })
        rt = roundtrip_for(cap)
        allow(rt).to receive(:plan_one).and_return(
          Absorb::Roundtrip::Outcome.new(kind: :dashboards, id: 'abc-def-ghi',
                                         name: 'n', status: :no_changes)
        )
        allow(rt).to receive(:provider_body).and_return({ 'title' => 'Production Overview' })

        result = rt.reconcile(credentials: { api_key: 'k', app_key: 'a' }, kinds: [:dashboards])

        expect(result.map { |r| r[:status] }).to eq([:refreshed])
        expect(cap.normalized(:dashboards, 'abc-def-ghi')['title']).to eq('Production Overview')
      end

      it 'leaves a good sidecar alone when it already plans clean' do
        cap = capture_with(dashboard_payload)
        rt = roundtrip_for(cap)
        allow(rt).to receive(:plan_one).and_return(
          Absorb::Roundtrip::Outcome.new(kind: :dashboards, id: 'abc-def-ghi',
                                         name: 'n', status: :no_changes)
        )
        expect(rt).not_to receive(:provider_body)

        result = rt.reconcile(credentials: { api_key: 'k', app_key: 'a' }, kinds: [:dashboards])

        expect(result.map { |r| r[:status] }).to eq([:already_clean])
      end
    end

    # A gate that cannot fail is worth nothing, so this drives it end to end:
    # emit from a sidecar, then age the CAPTURE underneath it.
    describe 'end to end' do
      around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

      it 'fails verify when the capture moves on and the sidecar does not' do
        cap = Absorb::Capture.new(File.join(@dir, 'estate'))
        cap.prepare
        cap.write(:dashboards, 'abc-def-ghi', dashboard_payload)
        cap.write_normalized(:dashboards, 'abc-def-ghi', dashboard_payload)
        out = File.join(@dir, 'generated')
        Absorb::Emit.new(capture: cap, out_dir: out, rules: rules).run

        expect(Absorb::Verify.new(capture: cap, out_dir: out).run).to be_ok

        edited = Marshal.load(Marshal.dump(dashboard_payload))
        edited['widgets'] << { 'id' => 999, 'definition' => { 'type' => 'note', 'title' => 'New' } }
        cap.write(:dashboards, 'abc-def-ghi', edited)

        result = Absorb::Verify.new(capture: cap, out_dir: out).run

        expect(result).not_to be_ok
        expect(result.diffs.map { |d| d[:attribute] }.join).to include('stale sidecar')
      end
    end
  end

  # Powerpacks. `datadog_powerpack` models widgets as 31 typed sub-blocks --
  # the shape that made the typed `datadog_dashboard` unusable -- and unlike
  # dashboards there is no `_json` escape hatch. So no projection of the API
  # payload works, and the ONLY viable body is the provider's own post-import
  # state, recorded by reconcile.
  describe 'powerpacks' do
    let(:payload) { { 'id' => 'pp1', 'attributes' => { 'name' => 'Network' } } }

    def capture_with_pack(sidecar: nil)
      cap = Absorb::Capture.new(File.join(@dir, 'estate'))
      cap.prepare
      cap.write(:powerpacks, 'pp1', payload)
      cap.write_normalized(:powerpacks, 'pp1', sidecar) if sidecar
      cap
    end

    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    it 'has no body at all until one is recorded' do
      expect(Absorb::Normalize.powerpack(payload, nil)).to be_nil
    end

    it 'builds the body from the recorded state' do
      body = Absorb::Normalize.powerpack(payload, { 'name' => 'Network', 'tags' => ['tag:akeyless'] })

      expect(body).to eq({ name: 'Network', tags: ['tag:akeyless'] })
    end

    # Emitting a half-formed powerpack would produce code terraform rejects.
    it 'skips an unreconciled powerpack rather than emitting one' do
      imports = Absorb::Emit.new(capture: capture_with_pack, out_dir: File.join(@dir, 'g'),
                                 rules: rules).run

      expect(imports).to be_empty
    end

    it 'emits a reconciled powerpack' do
      cap = capture_with_pack(sidecar: { 'name' => 'Network' })
      imports = Absorb::Emit.new(capture: cap, out_dir: File.join(@dir, 'g'), rules: rules).run

      expect(imports).to eq({ 'datadog_powerpack.network_pp1' => 'pp1' })
      expect(Absorb::Verify.new(capture: cap, out_dir: File.join(@dir, 'g')).run).to be_ok
    end

    # SINGLY_NESTED_ATTRIBUTES is baked data, so something must stop it drifting
    # from the declarations it describes. It cannot be read at run time: that
    # needs the 122-resource layer and dry-struct, and absorb's CLI runs on a
    # bare ruby without them -- introspecting turned `emit` into a hard failure
    # outside the gem environment. The specs DO have that environment, so the
    # check lives here.
    describe 'the singly-nested attribute table' do
      it 'matches what the typed resources actually declare' do
        Absorb::Normalize::SINGLY_NESTED_ATTRIBUTES.each do |resource, recorded|
          require "pangea/resources/#{resource}/resource"
          const = resource.to_s.split('_').map(&:capitalize).join
          klass = Pangea::Resources.const_get(const)
                                   .resource_definitions.fetch(resource)
                                   .fetch(:attributes_class)

          declared = klass.schema.select { |key| key.type.valid?({}) && !key.type.valid?([{}]) }
                          .map(&:name).sort

          expect(recorded.sort).to eq(declared), <<~MSG
            #{resource} singly-nested attributes drifted.
              recorded: #{recorded.sort.inspect}
              declared: #{declared.inspect}
            Update Normalize::SINGLY_NESTED_ATTRIBUTES.
          MSG
        end
      end

      it 'unwraps a one-element block and leaves a real list alone' do
        out = Absorb::Normalize.conform_to_declared_types(
          :datadog_powerpack,
          { layout: [{ x: 0 }], widget: [{ a: 1 }, { b: 2 }], tags: ['t'], name: 'n' }
        )

        expect(out[:layout]).to eq({ x: 0 })
        expect(out[:widget]).to eq([{ a: 1 }, { b: 2 }])
        expect(out[:tags]).to eq(['t'])
      end

      it 'leaves a resource with no singly-nested attributes untouched' do
        attrs = { filter: [{ query: 'q' }] }

        expect(Absorb::Normalize.conform_to_declared_types(:datadog_monitor, attrs)).to eq(attrs)
      end
    end

    # The provider's own post-import state carries values its own schema
    # rejects. Measured: with this prune 9 of 9 of the estate's powerpacks plan
    # to "No changes"; without it, 0 of 9.
    describe 'pruning the provider state' do
      def prune(v) = Absorb::Normalize.prune_provider_state(v)

      it 'drops an empty string, which is not a valid enum value' do
        expect(prune({ 'live_span' => '', 'name' => 'x' })).to eq({ 'name' => 'x' })
      end

      it 'drops a computed id at any depth' do
        expect(prune({ 'widget' => [{ 'id' => 9, 'q' => 'a' }] })).to eq({ 'widget' => [{ 'q' => 'a' }] })
      end

      it 'drops nulls and empty lists, which are absence' do
        expect(prune({ 'a' => nil, 'b' => [], 'c' => 1 })).to eq({ 'c' => 1 })
      end

      # This single distinction is the difference between 8/9 and 9/9: an empty
      # HASH is a declared block carrying no set fields (toplist_definition
      # .style), and dropping it is itself a diff.
      it 'KEEPS an empty block, which is declared rather than absent' do
        expect(prune({ 'style' => {}, 'n' => 1 })).to eq({ 'style' => {}, 'n' => 1 })
      end

      it 'keeps an empty block that only became empty after pruning' do
        expect(prune({ 'style' => { 'palette' => '' } })).to eq({ 'style' => {} })
      end
    end
  end

  # The account layer: teams, roles, RUM applications, APM retention filters
  # and dashboard lists.
  describe 'the account layer' do
    let(:managed_role) do
      { 'id' => 'r1', 'type' => 'roles',
        'attributes' => { 'name' => 'Datadog Admin Role', 'managed' => true },
        'relationships' => { 'permissions' => { 'data' => [{ 'id' => 'p1', 'type' => 'permissions' }] } } }
    end

    let(:custom_role) do
      { 'id' => 'r2', 'type' => 'roles',
        'attributes' => { 'name' => 'DataDog Read/Write' },
        'relationships' => { 'permissions' => { 'data' => [{ 'id' => 'p1', 'type' => 'permissions' }] } } }
    end

    it 'reads a team out of its attributes envelope' do
      body = Absorb::Normalize.team(
        { 'id' => 't', 'attributes' => { 'name' => 'Infra', 'handle' => 'infra',
                                         'description' => 'Devops - SRE', 'user_count' => 6 } }
      )

      expect(body).to eq({ description: 'Devops - SRE', handle: 'infra', name: 'Infra' })
    end

    # Datadog ships Admin / Standard / Read Only into every account. Unlike a
    # read-only pipeline there is no second resource to fall back to, so they
    # are not adoptable at all. 3 of this estate's 4 roles are managed.
    it 'tells a Datadog-managed role from a real one' do
      expect(Absorb::Normalize.role_managed?(managed_role)).to be(true)
      expect(Absorb::Normalize.role_managed?(custom_role)).to be(false)
    end

    it 'never emits a managed role' do
      Dir.mktmpdir do |dir|
        cap = Absorb::Capture.new(File.join(dir, 'estate'))
        cap.prepare
        cap.write(:roles, 'r1', managed_role)
        cap.write(:roles, 'r2', custom_role)
        imports = Absorb::Emit.new(capture: cap, out_dir: File.join(dir, 'g'), rules: rules).run

        expect(imports.keys).to eq(['datadog_role.datadog_read_write_r2'])
      end
    end

    it 'carries a role permission as an id block' do
      expect(Absorb::Normalize.role(custom_role)[:permission]).to eq([{ id: 'p1' }])
    end

    # The provider accepts exactly one filter_type and rejects the others at
    # VALIDATE, not as a diff -- emitting one would be code terraform refuses.
    # Both of this estate's filters are Datadog's own defaults.
    it 'refuses to emit an APM filter type the provider rejects' do
      default_filter = { 'id' => 'f1', 'attributes' => { 'name' => 'Error Default', 'enabled' => true,
                                                         'filter_type' => 'spans-errors-sampling-processor',
                                                         'rate' => 1 } }
      ours = { 'id' => 'f2', 'attributes' => { 'name' => 'Ours', 'enabled' => true,
                                               'filter_type' => 'spans-sampling-processor', 'rate' => 1 } }

      expect(Absorb::Normalize.apm_retention_filter_adoptable?(default_filter)).to be(false)
      expect(Absorb::Normalize.apm_retention_filter_adoptable?(ours)).to be(true)

      Dir.mktmpdir do |dir|
        cap = Absorb::Capture.new(File.join(dir, 'estate'))
        cap.prepare
        cap.write(:apm_retention_filters, 'f1', default_filter)
        cap.write(:apm_retention_filters, 'f2', ours)
        imports = Absorb::Emit.new(capture: cap, out_dir: File.join(dir, 'g'), rules: rules).run

        expect(imports.keys).to eq(['datadog_apm_retention_filter.ours_f2'])
      end
    end

    # The provider models rate and trace_rate as STRINGS while the API returns
    # numbers. Latent rather than harmless: both live filters are Datadog's own
    # defaults, which the provider rejects on filter_type before any type check,
    # so this would only have surfaced on the first genuinely adoptable filter.
    it 'emits the rates as strings, the way the provider declares them' do
      body = Absorb::Normalize.apm_retention_filter(
        { 'attributes' => { 'name' => 'Ours', 'enabled' => true,
                            'filter_type' => 'spans-sampling-processor',
                            'rate' => 1, 'trace_rate' => 0 } }
      )

      expect(body[:rate]).to eq('1')
      expect(body[:trace_rate]).to eq('0')
    end

    # A list's own record reports `dashboards: null`; membership arrives from a
    # second endpoint and IS the resource.
    it 'builds a dashboard list from its fetched membership' do
      body = Absorb::Normalize.dashboard_list(
        { 'id' => 1, 'name' => 'Saas', 'dashboards' => [{ 'id' => 'abc', 'type' => 'custom_timeboard' }] }
      )

      expect(body).to eq({ dash_item: [{ dash_id: 'abc', type: 'custom_timeboard' }], name: 'Saas' })
    end

    # `client_token` was screened for before this kind was added: the list
    # response carries none, so nothing credential-bearing reaches the code.
    it 'carries only the two RUM fields the provider models' do
      body = Absorb::Normalize.rum_application(
        { 'id' => 'a', 'attributes' => { 'name' => 'Mobile', 'type' => 'react-native',
                                         'api_key_id' => 'k', 'application_id' => 'x', 'tags' => ['a'] } }
      )

      expect(body).to eq({ name: 'Mobile', type: 'react-native' })
    end

    # RUM tags and replay sampling rates are authored settings the provider
    # does not model. Reporting them is the difference between a known gap and
    # a surprise after adoption.
    it 'reports the RUM settings the provider declines to model' do
      u = Absorb::Normalize.account_unmapped(
        'datadog_rum_application',
        { 'attributes' => { 'name' => 'M', 'tags' => ['env:prod'], 'api_key_id' => 'k' } }
      )

      expect(u[:fields]).to be_empty
      expect(u[:unmanageable]).to eq(['tags'])
    end
  end

  # Terraform parses every JSON string value as a TEMPLATE. Absorbed text is
  # data, and terraform read it as syntax: two of the five monitors previously
  # written off as estate defects were actually this.
  describe 'terraform template escaping' do
    def escape(v) = Absorb::Normalize.escape_terraform_templates(v)

    it 'escapes an interpolation opener in absorbed text' do
      expect(escape('Site24x7 ${{event.host.name}}')).to eq('Site24x7 $${{event.host.name}}')
    end

    it 'escapes a directive opener in a grok rule' do
      expect(escape('%{date("yyyy"):date}')).to eq('%%{date("yyyy"):date}')
    end

    # Applied by canonicalize, which several paths reach; a second pass must
    # not produce %%%{.
    it 'is idempotent' do
      once = escape('%{a} ${b}')

      expect(escape(once)).to eq(once)
    end

    it 'reaches nested values, not just the top level' do
      expect(escape({ a: [{ b: '%{x}' }] })).to eq({ a: [{ b: '%%{x}' }] })
    end

    it 'leaves text with no template sequence untouched' do
      expect(escape('avg(last_5m):avg:rabbitmq.node.mem_used{*} > 90'))
        .to eq('avg(last_5m):avg:rabbitmq.node.mem_used{*} > 90')
    end

    it 'escapes through a monitor body' do
      payload = monitor_payload.merge('name' => 'Site24x7 ${{event.host.name}}')

      expect(Absorb::Normalize.monitor(payload)[:name]).to eq('Site24x7 $${{event.host.name}}')
    end
  end

  # The API nests a LIST under `recurrences`; the provider names the same thing
  # `recurrence`. Both sides carried the same wrong key, so attribute-level
  # state matching could never see it -- only a real plan could.
  describe 'monitor custom schedule' do
    it 'renames recurrences to the provider block name' do
      out = Absorb::Normalize.monitor_scheduling_options(
        { 'custom_schedule' => { 'recurrences' => [{ 'rrule' => 'FREQ=WEEKLY',
                                                     'timezone' => 'Asia/Jerusalem' }] } }
      )

      expect(out['custom_schedule']).to eq(
        { 'recurrence' => [{ rrule: 'FREQ=WEEKLY', timezone: 'Asia/Jerusalem' }] }
      )
    end

    it 'keeps only the fields the provider declares' do
      out = Absorb::Normalize.monitor_scheduling_options(
        { 'custom_schedule' => { 'recurrences' => [{ 'rrule' => 'X', 'unknown_field' => 1 }] } }
      )

      expect(out['custom_schedule']['recurrence'].first).to eq({ rrule: 'X' })
    end

    it 'passes an evaluation-window-only scheduling block through' do
      value = { 'evaluation_window' => { 'day_starts' => '04:00' } }

      expect(Absorb::Normalize.monitor_scheduling_options(value)).to eq(value)
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

    # A REAL sidecar is the provider's read of the same object, so it agrees
    # with the capture on title, widget count, widget titles and template
    # variables -- it differs only in how it spells the body. The earlier
    # fixture here did not, and the stale-sidecar check was right to reject it.
    let(:provider_body) do
      { 'title' => 'Production Overview', 'layout_type' => 'ordered',
        'template_variables' => [{ 'name' => 'env', 'prefix' => 'env', 'default' => '*' }],
        'widgets' => [
          { 'id' => 111,
            'definition' => {
              'type' => 'group',
              'widgets' => [{ 'id' => 222,
                              'definition' => { 'type' => 'note', 'content' => 'from the provider' } }]
            } }
        ] }
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

      expect(JSON.parse(body[:dashboard]).dig('widgets', 0, 'definition', 'widgets', 0,
                                              'definition', 'content'))
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
