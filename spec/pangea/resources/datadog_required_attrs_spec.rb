# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'datadog resource required attribute validation' do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  before { synth.extend(Pangea::Resources::Datadog) }

  describe 'datadog_monitor' do
    it 'raises when name is missing' do
      expect {
        synth.datadog_monitor(:test, { type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when type is missing' do
      expect {
        synth.datadog_monitor(:test, { name: 'cpu-alert', query: 'avg:cpu{*} > 90', message: 'alert' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when query is missing' do
      expect {
        synth.datadog_monitor(:test, { name: 'cpu-alert', type: 'metric alert', message: 'alert' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when message is missing' do
      expect {
        synth.datadog_monitor(:test, { name: 'cpu-alert', type: 'metric alert', query: 'avg:cpu{*} > 90' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when all attributes are missing' do
      expect {
        synth.datadog_monitor(:test, {})
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_dashboard' do
    it 'raises when title is missing' do
      expect {
        synth.datadog_dashboard(:test, { layout_type: 'ordered' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when layout_type is missing' do
      expect {
        synth.datadog_dashboard(:test, { title: 'Overview' })
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_dashboard_json' do
    it 'raises when dashboard is missing' do
      expect {
        synth.datadog_dashboard_json(:test, {})
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_synthetics_test' do
    it 'raises when name is missing' do
      expect {
        synth.datadog_synthetics_test(:test, { type: 'api', status: 'live', locations: ['aws:us-east-1'] })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when type is missing' do
      expect {
        synth.datadog_synthetics_test(:test, { name: 'Check', status: 'live', locations: ['aws:us-east-1'] })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when status is missing' do
      expect {
        synth.datadog_synthetics_test(:test, { name: 'Check', type: 'api', locations: ['aws:us-east-1'] })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when locations is missing' do
      expect {
        synth.datadog_synthetics_test(:test, { name: 'Check', type: 'api', status: 'live' })
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_service_level_objective' do
    it 'raises when name is missing' do
      expect {
        synth.datadog_service_level_objective(:test, { type: 'metric', thresholds: '99.9' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when type is missing' do
      expect {
        synth.datadog_service_level_objective(:test, { name: 'SLO', thresholds: '99.9' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when thresholds is missing' do
      expect {
        synth.datadog_service_level_objective(:test, { name: 'SLO', type: 'metric' })
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_logs_index' do
    it 'raises when name is missing' do
      expect {
        synth.datadog_logs_index(:test, { filter: 'source:app' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when filter is missing' do
      expect {
        synth.datadog_logs_index(:test, { name: 'main' })
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_logs_pipeline' do
    it 'raises when name is missing' do
      expect {
        synth.datadog_logs_pipeline(:test, { filter: 'source:nginx' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when filter is missing' do
      expect {
        synth.datadog_logs_pipeline(:test, { name: 'nginx-pipeline' })
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_logs_metric' do
    it 'raises when name is missing' do
      expect {
        synth.datadog_logs_metric(:test, { compute: 'count' })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when compute is missing' do
      expect {
        synth.datadog_logs_metric(:test, { name: 'error_count' })
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_apm_retention_filter' do
    it 'raises when name is missing' do
      expect {
        synth.datadog_apm_retention_filter(:test, { enabled: true, filter_type: 'spans-errors-sampling-processor', rate: 1.0 })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when enabled is missing' do
      expect {
        synth.datadog_apm_retention_filter(:test, { name: 'f', filter_type: 'spans-errors-sampling-processor', rate: 1.0 })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when filter_type is missing' do
      expect {
        synth.datadog_apm_retention_filter(:test, { name: 'f', enabled: true, rate: 1.0 })
      }.to raise_error(Dry::Struct::Error)
    end

    it 'raises when rate is missing' do
      expect {
        synth.datadog_apm_retention_filter(:test, { name: 'f', enabled: true, filter_type: 'spans-errors-sampling-processor' })
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'datadog_integration_aws' do
    it 'raises when account_id is missing' do
      expect {
        synth.datadog_integration_aws(:test, {})
      }.to raise_error(Dry::Struct::Error)
    end
  end
end
