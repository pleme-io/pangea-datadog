# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'pangea-datadog provider' do
  include Pangea::Testing::SynthesisTestHelpers

  # ── Load Tests ─────────────────────────────────────────────────────────
  # Verify the gem loads without error and all modules are defined

  describe 'gem loading' do
    it 'loads pangea-datadog without error' do
      expect(defined?(Pangea::Resources::Datadog)).to be_truthy
    end

    it 'defines all resource modules' do
      expect(defined?(Pangea::Resources::DatadogMonitor)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogDashboard)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogDashboardJson)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogSyntheticsTest)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogServiceLevelObjective)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogLogsIndex)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogLogsPipeline)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogLogsMetric)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogApmRetentionFilter)).to be_truthy
      expect(defined?(Pangea::Resources::DatadogIntegrationAws)).to be_truthy
    end

    it 'registers all resource types in ResourceRegistry' do
      registry_modules = Pangea::ResourceRegistry.registered_modules
      expect(registry_modules).to include(Pangea::Resources::Datadog)
    end
  end

  # ── Synthesis Tests ────────────────────────────────────────────────────
  # Verify each resource synthesizes valid Terraform JSON

  let(:synth) { create_synthesizer }

  describe 'datadog_monitor' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { name: 'cpu-alert', type: 'metric alert', query: 'avg(last_5m):avg:system.cpu.user{*} > 90', message: 'CPU high' }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_monitor(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config).not_to be_nil
      expect(config['name']).to eq('cpu-alert')
      expect(config['type']).to eq('metric alert')
      expect(config['query']).to include('system.cpu.user')
      expect(config['message']).to eq('CPU high')
    end

    it 'returns ResourceReference with correct outputs' do
      ref = synth.datadog_monitor(:test, required_attrs)
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_monitor')
      expect(ref.outputs[:id]).to eq('${datadog_monitor.test.id}')
      expect(ref.outputs[:name]).to eq('${datadog_monitor.test.name}')
    end

    it 'includes optional attributes when provided' do
      synth.datadog_monitor(:test, required_attrs.merge(
        priority: 1,
        notify_no_data: true,
        tags: ['env:prod', 'team:infra'],
      ))
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['priority']).to eq(1)
      expect(config['notify_no_data']).to eq(true)
      expect(config['tags']).to eq(['env:prod', 'team:infra'])
    end

    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_monitor(:test, required_attrs.merge(bad_key: 'x'))
      }.to raise_error(ArgumentError, /unknown attributes.*bad_key/)
    end
  end

  describe 'datadog_dashboard' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { title: 'System Overview', layout_type: 'ordered' }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_dashboard(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config).not_to be_nil
      expect(config['title']).to eq('System Overview')
      expect(config['layout_type']).to eq('ordered')
    end

    it 'returns ResourceReference with url output' do
      ref = synth.datadog_dashboard(:test, required_attrs)
      expect(ref.outputs[:url]).to eq('${datadog_dashboard.test.url}')
    end

    it 'includes optional description' do
      synth.datadog_dashboard(:test, required_attrs.merge(description: 'Main dashboard'))
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['description']).to eq('Main dashboard')
    end
  end

  describe 'datadog_dashboard_json' do
    before { synth.extend(Pangea::Resources::Datadog) }

    it 'synthesizes with dashboard JSON string' do
      synth.datadog_dashboard_json(:test, { dashboard: '{"title":"Test"}' })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard_json', 'test')
      expect(config).not_to be_nil
      expect(config['dashboard']).to eq('{"title":"Test"}')
    end

    it 'returns ResourceReference with url output' do
      ref = synth.datadog_dashboard_json(:test, { dashboard: '{}' })
      expect(ref.outputs[:url]).to eq('${datadog_dashboard_json.test.url}')
    end
  end

  describe 'datadog_synthetics_test' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { name: 'API Check', type: 'api', status: 'live', locations: ['aws:us-east-1'] }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_synthetics_test(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_synthetics_test', 'test')
      expect(config).not_to be_nil
      expect(config['name']).to eq('API Check')
      expect(config['type']).to eq('api')
      expect(config['status']).to eq('live')
      expect(config['locations']).to eq(['aws:us-east-1'])
    end

    it 'returns ResourceReference with monitor_id output' do
      ref = synth.datadog_synthetics_test(:test, required_attrs)
      expect(ref.outputs[:monitor_id]).to eq('${datadog_synthetics_test.test.monitor_id}')
    end
  end

  describe 'datadog_service_level_objective' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { name: 'API Availability', type: 'metric', thresholds: '99.9' }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_service_level_objective(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_service_level_objective', 'test')
      expect(config).not_to be_nil
      expect(config['name']).to eq('API Availability')
      expect(config['type']).to eq('metric')
    end
  end

  describe 'datadog_logs_index' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { name: 'main', filter: 'source:app' }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_logs_index(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_index', 'test')
      expect(config).not_to be_nil
      expect(config['name']).to eq('main')
      expect(config['filter']).to eq('source:app')
    end

    it 'includes optional retention_days' do
      synth.datadog_logs_index(:test, required_attrs.merge(retention_days: 30))
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_index', 'test')
      expect(config['retention_days']).to eq(30)
    end
  end

  describe 'datadog_logs_pipeline' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { name: 'nginx-pipeline', filter: 'source:nginx' }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_logs_pipeline(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_pipeline', 'test')
      expect(config).not_to be_nil
      expect(config['name']).to eq('nginx-pipeline')
    end
  end

  describe 'datadog_logs_metric' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { name: 'error_count', compute: 'count' }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_logs_metric(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_metric', 'test')
      expect(config).not_to be_nil
      expect(config['name']).to eq('error_count')
      expect(config['compute']).to eq('count')
    end
  end

  describe 'datadog_apm_retention_filter' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { name: 'error-traces', enabled: true, filter_type: 'spans-errors-sampling-processor', rate: 1.0 }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_apm_retention_filter(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_apm_retention_filter', 'test')
      expect(config).not_to be_nil
      expect(config['name']).to eq('error-traces')
      expect(config['filter_type']).to eq('spans-errors-sampling-processor')
      expect(config['rate']).to eq(1.0)
    end

    it 'renders enabled boolean via map_bool' do
      synth.datadog_apm_retention_filter(:test, required_attrs.merge(enabled: false))
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_apm_retention_filter', 'test')
      expect(config['enabled']).to eq(false)
    end
  end

  describe 'datadog_integration_aws' do
    before { synth.extend(Pangea::Resources::Datadog) }

    let(:required_attrs) do
      { account_id: '123456789012' }
    end

    it 'synthesizes with required attributes' do
      synth.datadog_integration_aws(:test, required_attrs)
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config).not_to be_nil
      expect(config['account_id']).to eq('123456789012')
    end

    it 'returns ResourceReference with external_id output' do
      ref = synth.datadog_integration_aws(:test, required_attrs)
      expect(ref.outputs[:external_id]).to eq('${datadog_integration_aws.test.external_id}')
    end

    it 'includes optional role_name and host_tags' do
      synth.datadog_integration_aws(:test, required_attrs.merge(
        role_name: 'DatadogIntegrationRole',
        host_tags: ['env:prod'],
      ))
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['role_name']).to eq('DatadogIntegrationRole')
      expect(config['host_tags']).to eq(['env:prod'])
    end
  end

  # ── Cross-Resource Tests ───────────────────────────────────────────────

  describe 'Datadog aggregator module' do
    before { synth.extend(Pangea::Resources::Datadog) }

    it 'exposes all resource methods through single module' do
      expect(synth).to respond_to(:datadog_monitor)
      expect(synth).to respond_to(:datadog_dashboard)
      expect(synth).to respond_to(:datadog_dashboard_json)
      expect(synth).to respond_to(:datadog_synthetics_test)
      expect(synth).to respond_to(:datadog_service_level_objective)
      expect(synth).to respond_to(:datadog_logs_index)
      expect(synth).to respond_to(:datadog_logs_pipeline)
      expect(synth).to respond_to(:datadog_logs_metric)
      expect(synth).to respond_to(:datadog_apm_retention_filter)
      expect(synth).to respond_to(:datadog_integration_aws)
    end

    it 'synthesizes multiple resources in a single synthesizer' do
      synth.datadog_monitor(:mon, { name: 'cpu', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert' })
      synth.datadog_dashboard(:dash, { title: 'Overview', layout_type: 'ordered' })
      result = normalize_synthesis(synth.synthesis)

      expect(result.dig('resource', 'datadog_monitor', 'mon')).not_to be_nil
      expect(result.dig('resource', 'datadog_dashboard', 'dash')).not_to be_nil
    end
  end
end
