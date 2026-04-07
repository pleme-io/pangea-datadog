# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'datadog resource reference outputs' do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  before { synth.extend(Pangea::Resources::Datadog) }

  describe 'datadog_monitor' do
    it 'has id and name outputs' do
      ref = synth.datadog_monitor(:mon1, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert'
      })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_monitor')
      expect(ref.outputs[:id]).to eq('${datadog_monitor.mon1.id}')
      expect(ref.outputs[:name]).to eq('${datadog_monitor.mon1.name}')
    end
  end

  describe 'datadog_dashboard' do
    it 'has id and url outputs' do
      ref = synth.datadog_dashboard(:d1, { title: 'T', layout_type: 'ordered' })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_dashboard')
      expect(ref.outputs[:id]).to eq('${datadog_dashboard.d1.id}')
      expect(ref.outputs[:url]).to eq('${datadog_dashboard.d1.url}')
    end
  end

  describe 'datadog_dashboard_json' do
    it 'has id and url outputs' do
      ref = synth.datadog_dashboard_json(:dj1, { dashboard: '{}' })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_dashboard_json')
      expect(ref.outputs[:id]).to eq('${datadog_dashboard_json.dj1.id}')
      expect(ref.outputs[:url]).to eq('${datadog_dashboard_json.dj1.url}')
    end
  end

  describe 'datadog_synthetics_test' do
    it 'has id and monitor_id outputs' do
      ref = synth.datadog_synthetics_test(:s1, {
        name: 'Check', type: 'api', status: 'live', locations: ['aws:us-east-1']
      })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_synthetics_test')
      expect(ref.outputs[:id]).to eq('${datadog_synthetics_test.s1.id}')
      expect(ref.outputs[:monitor_id]).to eq('${datadog_synthetics_test.s1.monitor_id}')
    end
  end

  describe 'datadog_service_level_objective' do
    it 'has id and name outputs' do
      ref = synth.datadog_service_level_objective(:slo1, {
        name: 'SLO', type: 'metric', thresholds: '99.9'
      })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_service_level_objective')
      expect(ref.outputs[:id]).to eq('${datadog_service_level_objective.slo1.id}')
      expect(ref.outputs[:name]).to eq('${datadog_service_level_objective.slo1.name}')
    end
  end

  describe 'datadog_logs_index' do
    it 'has id and name outputs' do
      ref = synth.datadog_logs_index(:li1, { name: 'main', filter: 'source:app' })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_logs_index')
      expect(ref.outputs[:id]).to eq('${datadog_logs_index.li1.id}')
      expect(ref.outputs[:name]).to eq('${datadog_logs_index.li1.name}')
    end
  end

  describe 'datadog_logs_pipeline' do
    it 'has id and name outputs' do
      ref = synth.datadog_logs_pipeline(:lp1, { name: 'p', filter: 'source:nginx' })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_logs_pipeline')
      expect(ref.outputs[:id]).to eq('${datadog_logs_pipeline.lp1.id}')
      expect(ref.outputs[:name]).to eq('${datadog_logs_pipeline.lp1.name}')
    end
  end

  describe 'datadog_logs_metric' do
    it 'has id and name outputs' do
      ref = synth.datadog_logs_metric(:lm1, { name: 'err', compute: 'count' })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_logs_metric')
      expect(ref.outputs[:id]).to eq('${datadog_logs_metric.lm1.id}')
      expect(ref.outputs[:name]).to eq('${datadog_logs_metric.lm1.name}')
    end
  end

  describe 'datadog_apm_retention_filter' do
    it 'has id and name outputs' do
      ref = synth.datadog_apm_retention_filter(:arf1, {
        name: 'f', enabled: true, filter_type: 'spans-errors-sampling-processor', rate: 1.0
      })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_apm_retention_filter')
      expect(ref.outputs[:id]).to eq('${datadog_apm_retention_filter.arf1.id}')
      expect(ref.outputs[:name]).to eq('${datadog_apm_retention_filter.arf1.name}')
    end
  end

  describe 'datadog_integration_aws' do
    it 'has id and external_id outputs' do
      ref = synth.datadog_integration_aws(:aws1, { account_id: '123456789012' })
      expect(ref).to be_a(Pangea::Resources::ResourceReference)
      expect(ref.type).to eq('datadog_integration_aws')
      expect(ref.outputs[:id]).to eq('${datadog_integration_aws.aws1.id}')
      expect(ref.outputs[:external_id]).to eq('${datadog_integration_aws.aws1.external_id}')
    end
  end

  describe 'resource name in reference interpolations' do
    it 'uses the user-provided resource name in the Terraform reference' do
      ref = synth.datadog_monitor(:my_custom_name, {
        name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert'
      })
      expect(ref.outputs[:id]).to eq('${datadog_monitor.my_custom_name.id}')
    end

    it 'handles symbolic resource names with underscores' do
      ref = synth.datadog_dashboard(:prod_overview_dash, { title: 'T', layout_type: 'ordered' })
      expect(ref.outputs[:id]).to eq('${datadog_dashboard.prod_overview_dash.id}')
    end
  end
end
