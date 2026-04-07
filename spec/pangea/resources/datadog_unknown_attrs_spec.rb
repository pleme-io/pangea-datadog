# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'datadog resource unknown attribute rejection' do
  include Pangea::Testing::SynthesisTestHelpers

  let(:synth) { create_synthesizer }
  before { synth.extend(Pangea::Resources::Datadog) }

  describe 'datadog_dashboard' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_dashboard(:test, { title: 'T', layout_type: 'ordered', bogus_key: 'x' })
      }.to raise_error(ArgumentError, /unknown attributes.*bogus_key/)
    end
  end

  describe 'datadog_dashboard_json' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_dashboard_json(:test, { dashboard: '{}', unknown: true })
      }.to raise_error(ArgumentError, /unknown attributes.*unknown/)
    end
  end

  describe 'datadog_synthetics_test' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_synthetics_test(:test, {
          name: 'Check', type: 'api', status: 'live',
          locations: ['aws:us-east-1'], not_real: 42
        })
      }.to raise_error(ArgumentError, /unknown attributes.*not_real/)
    end
  end

  describe 'datadog_service_level_objective' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_service_level_objective(:test, {
          name: 'SLO', type: 'metric', thresholds: '99.9', invalid_attr: 'z'
        })
      }.to raise_error(ArgumentError, /unknown attributes.*invalid_attr/)
    end
  end

  describe 'datadog_logs_index' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_logs_index(:test, { name: 'main', filter: 'source:app', extra: 'bad' })
      }.to raise_error(ArgumentError, /unknown attributes.*extra/)
    end
  end

  describe 'datadog_logs_pipeline' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_logs_pipeline(:test, { name: 'p', filter: 'source:nginx', junk: 1 })
      }.to raise_error(ArgumentError, /unknown attributes.*junk/)
    end
  end

  describe 'datadog_logs_metric' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_logs_metric(:test, { name: 'err', compute: 'count', nope: 'x' })
      }.to raise_error(ArgumentError, /unknown attributes.*nope/)
    end
  end

  describe 'datadog_apm_retention_filter' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_apm_retention_filter(:test, {
          name: 'f', enabled: true, filter_type: 'spans-errors-sampling-processor',
          rate: 1.0, fabricated: true
        })
      }.to raise_error(ArgumentError, /unknown attributes.*fabricated/)
    end
  end

  describe 'datadog_integration_aws' do
    it 'rejects unknown attribute keys' do
      expect {
        synth.datadog_integration_aws(:test, { account_id: '123', invented: 'y' })
      }.to raise_error(ArgumentError, /unknown attributes.*invented/)
    end
  end
end
