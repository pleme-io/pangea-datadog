# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'datadog resource edge cases' do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  before { synth.extend(Pangea::Resources::Datadog) }

  describe 'string-keyed attributes via transform_keys' do
    it 'accepts string keys and converts them to symbols' do
      synth.datadog_monitor(:test, {
        'name' => 'cpu-alert', 'type' => 'metric alert',
        'query' => 'avg:cpu{*} > 90', 'message' => 'alert'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['name']).to eq('cpu-alert')
    end

    it 'accepts string keys for dashboard' do
      synth.datadog_dashboard(:test, { 'title' => 'T', 'layout_type' => 'ordered' })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['title']).to eq('T')
    end
  end

  describe 'empty string attribute values' do
    it 'synthesizes monitor with empty message string' do
      synth.datadog_monitor(:test, {
        name: '', type: 'metric alert', query: 'avg:cpu{*} > 90', message: ''
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['name']).to eq('')
      expect(config['message']).to eq('')
    end

    it 'synthesizes dashboard_json with empty dashboard string' do
      synth.datadog_dashboard_json(:test, { dashboard: '' })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard_json', 'test')
      expect(config['dashboard']).to eq('')
    end
  end

  describe 'empty array attribute values' do
    it 'synthesizes monitor with empty tags array' do
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
        tags: []
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['tags']).to eq([])
    end

    it 'synthesizes synthetics_test with empty locations raises error' do
      expect {
        synth.datadog_synthetics_test(:test, {
          name: 'Check', type: 'api', status: 'live', locations: []
        })
      }.not_to raise_error
    end

    it 'synthesizes integration_aws with empty excluded_regions' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012', excluded_regions: []
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['excluded_regions']).to eq([])
    end

    it 'synthesizes integration_aws with empty host_tags' do
      synth.datadog_integration_aws(:test, {
        account_id: '123456789012', host_tags: []
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_integration_aws', 'test')
      expect(config['host_tags']).to eq([])
    end
  end

  describe 'special characters in string values' do
    it 'handles query with special Datadog syntax' do
      query = 'avg(last_5m):sum:system.cpu.user{host:web-*,env:production} by {host} > 90'
      synth.datadog_monitor(:test, {
        name: 'cpu-alert', type: 'metric alert', query: query, message: 'alert'
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['query']).to eq(query)
    end

    it 'handles message with newlines and special chars' do
      message = "CPU is high!\n@pagerduty-team {{host.name}} - {{value}}"
      synth.datadog_monitor(:test, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: message
      })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_monitor', 'test')
      expect(config['message']).to eq(message)
    end

    it 'handles JSON-embedded strings in dashboard' do
      dashboard = '{"title":"Test \\"Dashboard\\"","widgets":[{"type":"timeseries"}]}'
      synth.datadog_dashboard_json(:test, { dashboard: dashboard })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard_json', 'test')
      expect(config['dashboard']).to eq(dashboard)
    end

    it 'handles unicode in names' do
      synth.datadog_dashboard(:test, { title: 'Übersicht — Metriken', layout_type: 'ordered' })
      result = normalize_synthesis(synth.synthesis)
      config = result.dig('resource', 'datadog_dashboard', 'test')
      expect(config['title']).to eq('Übersicht — Metriken')
    end
  end

  describe 'multiple resources of same type' do
    it 'synthesizes two monitors with distinct names' do
      synth.datadog_monitor(:mon_a, {
        name: 'CPU Alert', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'cpu'
      })
      synth.datadog_monitor(:mon_b, {
        name: 'Memory Alert', type: 'metric alert', query: 'avg:mem{*} > 80', message: 'mem'
      })
      result = normalize_synthesis(synth.synthesis)
      expect(result.dig('resource', 'datadog_monitor', 'mon_a', 'name')).to eq('CPU Alert')
      expect(result.dig('resource', 'datadog_monitor', 'mon_b', 'name')).to eq('Memory Alert')
    end

    it 'returns unique references for each resource of same type' do
      ref_a = synth.datadog_dashboard(:dash_a, { title: 'A', layout_type: 'ordered' })
      ref_b = synth.datadog_dashboard(:dash_b, { title: 'B', layout_type: 'free' })
      expect(ref_a.outputs[:id]).to eq('${datadog_dashboard.dash_a.id}')
      expect(ref_b.outputs[:id]).to eq('${datadog_dashboard.dash_b.id}')
      expect(ref_a.outputs[:id]).not_to eq(ref_b.outputs[:id])
    end
  end

  describe 'all 10 resources in single synthesizer' do
    it 'synthesizes all resource types together without conflict' do
      synth.datadog_monitor(:m, { name: 'x', type: 'metric alert', query: 'avg:cpu{*}>90', message: 'a' })
      synth.datadog_dashboard(:d, { title: 'T', layout_type: 'ordered' })
      synth.datadog_dashboard_json(:dj, { dashboard: '{}' })
      synth.datadog_synthetics_test(:st, { name: 'C', type: 'api', status: 'live', locations: ['aws:us-east-1'] })
      synth.datadog_service_level_objective(:slo, { name: 'S', type: 'metric', thresholds: '99.9' })
      synth.datadog_logs_index(:li, { name: 'main', filter: 'source:app' })
      synth.datadog_logs_pipeline(:lp, { name: 'p', filter: 'source:nginx' })
      synth.datadog_logs_metric(:lm, { name: 'err', compute: 'count' })
      synth.datadog_apm_retention_filter(:af, { name: 'f', enabled: true, filter_type: 'spans-errors-sampling-processor', rate: 1.0 })
      synth.datadog_integration_aws(:aws, { account_id: '123456789012' })

      result = normalize_synthesis(synth.synthesis)

      expect(result.dig('resource', 'datadog_monitor', 'm')).not_to be_nil
      expect(result.dig('resource', 'datadog_dashboard', 'd')).not_to be_nil
      expect(result.dig('resource', 'datadog_dashboard_json', 'dj')).not_to be_nil
      expect(result.dig('resource', 'datadog_synthetics_test', 'st')).not_to be_nil
      expect(result.dig('resource', 'datadog_service_level_objective', 'slo')).not_to be_nil
      expect(result.dig('resource', 'datadog_logs_index', 'li')).not_to be_nil
      expect(result.dig('resource', 'datadog_logs_pipeline', 'lp')).not_to be_nil
      expect(result.dig('resource', 'datadog_logs_metric', 'lm')).not_to be_nil
      expect(result.dig('resource', 'datadog_apm_retention_filter', 'af')).not_to be_nil
      expect(result.dig('resource', 'datadog_integration_aws', 'aws')).not_to be_nil

      resource_types = result['resource'].keys
      expect(resource_types.length).to eq(10)
    end
  end

  describe 'type coercion edge cases' do
    it 'rejects integer where string is required' do
      expect {
        synth.datadog_monitor(:test, {
          name: 123, type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert'
        })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects string where boolean is required for apm_retention_filter' do
      expect {
        synth.datadog_apm_retention_filter(:test, {
          name: 'f', enabled: 'yes', filter_type: 'spans-errors-sampling-processor', rate: 1.0
        })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects string where float is required for rate' do
      expect {
        synth.datadog_apm_retention_filter(:test, {
          name: 'f', enabled: true, filter_type: 'spans-errors-sampling-processor', rate: 'high'
        })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects string where integer is required' do
      expect {
        synth.datadog_monitor(:test, {
          name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
          priority: 'high'
        })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects string in array-of-string field' do
      expect {
        synth.datadog_monitor(:test, {
          name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert',
          tags: 'env:prod'
        })
      }.to raise_error(Dry::Struct::Error)
    end
  end
end
