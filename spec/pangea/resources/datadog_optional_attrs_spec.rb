# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'datadog resource optional attribute synthesis' do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  before { synth.extend(Pangea::Resources::Datadog) }

  describe 'datadog_monitor optional map_present fields' do
    it 'synthesizes escalation_message when provided' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        escalation_message: 'Escalation!'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['escalation_message']).to eq('Escalation!')
    end

    it 'synthesizes evaluation_delay as integer' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        evaluation_delay: 300
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['evaluation_delay']).to eq(300)
    end

    it 'synthesizes new_group_delay and no_data_timeframe' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        new_group_delay: 60, no_data_timeframe: 10
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['new_group_delay']).to eq(60)
      expect(config['no_data_timeframe']).to eq(10)
    end

    it 'synthesizes renotify_interval and timeout_h' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        renotify_interval: 120, timeout_h: 24
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['renotify_interval']).to eq(120)
      expect(config['timeout_h']).to eq(24)
    end

    it 'synthesizes restricted_roles as array' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        restricted_roles: ['role-id-1', 'role-id-2']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['restricted_roles']).to eq(['role-id-1', 'role-id-2'])
    end

    it 'omits optional fields not provided' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config).not_to have_key('escalation_message')
      expect(config).not_to have_key('evaluation_delay')
      expect(config).not_to have_key('priority')
      expect(config).not_to have_key('renotify_interval')
    end
  end

  describe 'datadog_monitor map_bool fields' do
    it 'synthesizes enable_logs_sample true' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        enable_logs_sample: true
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['enable_logs_sample']).to eq(true)
    end

    it 'synthesizes enable_logs_sample false' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        enable_logs_sample: false
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['enable_logs_sample']).to eq(false)
    end

    it 'synthesizes groupby_simple_monitor' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        groupby_simple_monitor: true
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['groupby_simple_monitor']).to eq(true)
    end

    it 'synthesizes include_tags' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        include_tags: false
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['include_tags']).to eq(false)
    end
  end

  describe 'datadog_dashboard optional fields' do
    it 'synthesizes notify_list' do
      synth.datadog_dashboard(:test, {
        title: 'T', layout_type: 'ordered', notify_list: ['user@example.com']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['notify_list']).to eq(['user@example.com'])
    end

    it 'synthesizes reflow_type' do
      synth.datadog_dashboard(:test, {
        title: 'T', layout_type: 'free', reflow_type: 'auto'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['reflow_type']).to eq('auto')
    end

    it 'synthesizes tags' do
      synth.datadog_dashboard(:test, {
        title: 'T', layout_type: 'ordered', tags: ['env:prod', 'team:sre']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['tags']).to eq(['env:prod', 'team:sre'])
    end

    it 'synthesizes is_read_only boolean via map_bool' do
      synth.datadog_dashboard(:test, {
        title: 'T', layout_type: 'ordered', is_read_only: true
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['is_read_only']).to eq(true)
    end

    it 'synthesizes is_read_only false via map_bool' do
      synth.datadog_dashboard(:test, {
        title: 'T', layout_type: 'ordered', is_read_only: false
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['is_read_only']).to eq(false)
    end

    it 'synthesizes template_variables' do
      synth.datadog_dashboard(:test, {
        title: 'T', layout_type: 'ordered', template_variables: ['host', 'env']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['template_variables']).to eq(['host', 'env'])
    end

    it 'synthesizes widgets' do
      synth.datadog_dashboard(:test, {
        title: 'T', layout_type: 'ordered', widgets: '{"type":"timeseries"}'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['widgets']).to eq('{"type":"timeseries"}')
    end
  end

  describe 'datadog_synthetics_test optional fields' do
    it 'synthesizes config' do
      synth.datadog_synthetics_test(:test, {
        name: 'Check', type: 'api', status: 'live', locations: ['aws:us-east-1'],
        config: '{"request":{"url":"https://example.com"}}'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_synthetics_test', 'test')
      expect(config['config']).to include('example.com')
    end

    it 'synthesizes message' do
      synth.datadog_synthetics_test(:test, {
        name: 'Check', type: 'api', status: 'live', locations: ['aws:us-east-1'],
        message: 'Test failed'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_synthetics_test', 'test')
      expect(config['message']).to eq('Test failed')
    end

    it 'synthesizes options' do
      synth.datadog_synthetics_test(:test, {
        name: 'Check', type: 'api', status: 'live', locations: ['aws:us-east-1'],
        options: '{"tick_every":300}'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_synthetics_test', 'test')
      expect(config['options']).to eq('{"tick_every":300}')
    end

    it 'synthesizes subtype' do
      synth.datadog_synthetics_test(:test, {
        name: 'Check', type: 'api', status: 'live', locations: ['aws:us-east-1'],
        subtype: 'http'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_synthetics_test', 'test')
      expect(config['subtype']).to eq('http')
    end

    it 'synthesizes tags' do
      synth.datadog_synthetics_test(:test, {
        name: 'Check', type: 'api', status: 'live', locations: ['aws:us-east-1'],
        tags: ['env:staging']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_synthetics_test', 'test')
      expect(config['tags']).to eq(['env:staging'])
    end
  end

  describe 'datadog_service_level_objective optional fields' do
    it 'synthesizes description' do
      synth.datadog_service_level_objective(:test, {
        name: 'SLO', type: 'metric', thresholds: '99.9', description: 'API uptime SLO'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_service_level_objective', 'test')
      expect(config['description']).to eq('API uptime SLO')
    end

    it 'synthesizes groups' do
      synth.datadog_service_level_objective(:test, {
        name: 'SLO', type: 'metric', thresholds: '99.9', groups: ['env:prod']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_service_level_objective', 'test')
      expect(config['groups']).to eq(['env:prod'])
    end

    it 'synthesizes monitor_ids' do
      synth.datadog_service_level_objective(:test, {
        name: 'SLO', type: 'monitor', thresholds: '99.9', monitor_ids: [12345, 67890]
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_service_level_objective', 'test')
      expect(config['monitor_ids']).to eq([12345, 67890])
    end

    it 'synthesizes query' do
      synth.datadog_service_level_objective(:test, {
        name: 'SLO', type: 'metric', thresholds: '99.9', query: 'sum:requests.success{*}'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_service_level_objective', 'test')
      expect(config['query']).to eq('sum:requests.success{*}')
    end

    it 'synthesizes tags' do
      synth.datadog_service_level_objective(:test, {
        name: 'SLO', type: 'metric', thresholds: '99.9', tags: ['service:api']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_service_level_objective', 'test')
      expect(config['tags']).to eq(['service:api'])
    end

    it 'synthesizes target_threshold and warning_threshold as floats' do
      synth.datadog_service_level_objective(:test, {
        name: 'SLO', type: 'metric', thresholds: '99.9',
        target_threshold: 99.5, warning_threshold: 99.8
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_service_level_objective', 'test')
      expect(config['target_threshold']).to eq(99.5)
      expect(config['warning_threshold']).to eq(99.8)
    end

    it 'synthesizes timeframe' do
      synth.datadog_service_level_objective(:test, {
        name: 'SLO', type: 'metric', thresholds: '99.9', timeframe: '30d'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_service_level_objective', 'test')
      expect(config['timeframe']).to eq('30d')
    end
  end

  describe 'datadog_logs_index optional fields' do
    it 'synthesizes daily_limit' do
      synth.datadog_logs_index(:test, { name: 'main', filter: 'source:app', daily_limit: 1000000 })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_index', 'test')
      expect(config['daily_limit']).to eq(1000000)
    end

    it 'synthesizes daily_limit_reset' do
      synth.datadog_logs_index(:test, { name: 'main', filter: 'source:app', daily_limit_reset: '14:00' })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_index', 'test')
      expect(config['daily_limit_reset']).to eq('14:00')
    end

    it 'synthesizes daily_limit_warning_threshold_percentage' do
      synth.datadog_logs_index(:test, {
        name: 'main', filter: 'source:app', daily_limit_warning_threshold_percentage: 80.0
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_index', 'test')
      expect(config['daily_limit_warning_threshold_percentage']).to eq(80.0)
    end

    it 'synthesizes exclusion_filters' do
      synth.datadog_logs_index(:test, {
        name: 'main', filter: 'source:app', exclusion_filters: '{"name":"exclude-debug"}'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_index', 'test')
      expect(config['exclusion_filters']).to include('exclude-debug')
    end

    it 'synthesizes disable_daily_limit via map_bool' do
      synth.datadog_logs_index(:test, { name: 'main', filter: 'source:app', disable_daily_limit: true })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_index', 'test')
      expect(config['disable_daily_limit']).to eq(true)
    end

    it 'synthesizes disable_daily_limit false via map_bool' do
      synth.datadog_logs_index(:test, { name: 'main', filter: 'source:app', disable_daily_limit: false })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_index', 'test')
      expect(config['disable_daily_limit']).to eq(false)
    end
  end

  describe 'datadog_logs_pipeline optional fields' do
    it 'synthesizes processors' do
      synth.datadog_logs_pipeline(:test, {
        name: 'p', filter: 'source:nginx', processors: '{"type":"grok-parser"}'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_pipeline', 'test')
      expect(config['processors']).to include('grok-parser')
    end

    it 'synthesizes is_enabled true via map_bool' do
      synth.datadog_logs_pipeline(:test, { name: 'p', filter: 'source:nginx', is_enabled: true })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_pipeline', 'test')
      expect(config['is_enabled']).to eq(true)
    end

    it 'synthesizes is_enabled false via map_bool' do
      synth.datadog_logs_pipeline(:test, { name: 'p', filter: 'source:nginx', is_enabled: false })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_pipeline', 'test')
      expect(config['is_enabled']).to eq(false)
    end
  end

  describe 'datadog_logs_metric optional fields' do
    it 'synthesizes filter' do
      synth.datadog_logs_metric(:test, { name: 'err', compute: 'count', filter: 'status:error' })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_metric', 'test')
      expect(config['filter']).to eq('status:error')
    end

    it 'synthesizes group_by' do
      synth.datadog_logs_metric(:test, { name: 'err', compute: 'count', group_by: 'host' })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_logs_metric', 'test')
      expect(config['group_by']).to eq('host')
    end
  end

  describe 'datadog_apm_retention_filter optional fields' do
    it 'synthesizes filter' do
      synth.datadog_apm_retention_filter(:test, {
        name: 'f', enabled: true, filter_type: 'spans-errors-sampling-processor',
        rate: 1.0, filter: 'service:web'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_apm_retention_filter', 'test')
      expect(config['filter']).to eq('service:web')
    end
  end

  describe 'datadog_integration_aws optional fields' do
    it 'synthesizes access_key_id and secret_access_key' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012',
        access_key_id: 'AKIAIOSFODNN7EXAMPLE',
        secret_access_key: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['access_key_id']).to eq('AKIAIOSFODNN7EXAMPLE')
      expect(config['secret_access_key']).to include('EXAMPLEKEY')
    end

    it 'synthesizes excluded_regions' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012', excluded_regions: ['us-west-2', 'eu-west-1']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['excluded_regions']).to eq(['us-west-2', 'eu-west-1'])
    end

    it 'synthesizes filter_tags' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012', filter_tags: ['env:production']
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['filter_tags']).to eq(['env:production'])
    end

    it 'synthesizes account_specific_namespace_rules' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012', account_specific_namespace_rules: '{"auto_scaling":false}'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['account_specific_namespace_rules']).to include('auto_scaling')
    end

    it 'synthesizes cspm_resource_collection_enabled via map_bool' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012', cspm_resource_collection_enabled: true
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['cspm_resource_collection_enabled']).to eq(true)
    end

    it 'synthesizes metrics_collection_enabled via map_bool' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012', metrics_collection_enabled: false
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['metrics_collection_enabled']).to eq(false)
    end

    it 'synthesizes resource_collection_enabled via map_bool' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012', resource_collection_enabled: true
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['resource_collection_enabled']).to eq(true)
    end
  end
end
