# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Dry::Struct attribute classes' do
  describe 'MonitorAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::MonitorAttributes }

    it 'constructs with all required attributes' do
      attrs = klass.new(name: 'x', type: 'metric alert', query: 'avg:cpu{*} > 90', message: 'alert')
      expect(attrs.name).to eq('x')
      expect(attrs.type).to eq('metric alert')
      expect(attrs.query).to eq('avg:cpu{*} > 90')
      expect(attrs.message).to eq('alert')
    end

    it 'sets optional attributes to nil by default' do
      attrs = klass.new(name: 'x', type: 'metric alert', query: 'q', message: 'm')
      expect(attrs.priority).to be_nil
      expect(attrs.tags).to be_nil
      expect(attrs.enable_logs_sample).to be_nil
    end

    it 'accepts optional attributes when provided' do
      attrs = klass.new(
        name: 'x', type: 'metric alert', query: 'q', message: 'm',
        priority: 2, tags: ['env:prod'], enable_logs_sample: true,
        escalation_message: 'esc', evaluation_delay: 60,
        groupby_simple_monitor: false, include_tags: true,
        new_group_delay: 30, no_data_timeframe: 5,
        notify_no_data: true, renotify_interval: 120,
        restricted_roles: ['role1'], timeout_h: 24
      )
      expect(attrs.priority).to eq(2)
      expect(attrs.tags).to eq(['env:prod'])
      expect(attrs.escalation_message).to eq('esc')
      expect(attrs.evaluation_delay).to eq(60)
      expect(attrs.groupby_simple_monitor).to eq(false)
      expect(attrs.include_tags).to eq(true)
      expect(attrs.new_group_delay).to eq(30)
      expect(attrs.no_data_timeframe).to eq(5)
      expect(attrs.notify_no_data).to eq(true)
      expect(attrs.renotify_interval).to eq(120)
      expect(attrs.restricted_roles).to eq(['role1'])
      expect(attrs.timeout_h).to eq(24)
    end
  end

  describe 'DashboardAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::DashboardAttributes }

    it 'constructs with required attributes' do
      attrs = klass.new(title: 'T', layout_type: 'ordered')
      expect(attrs.title).to eq('T')
      expect(attrs.layout_type).to eq('ordered')
    end

    it 'sets optional attributes to nil by default' do
      attrs = klass.new(title: 'T', layout_type: 'ordered')
      expect(attrs.description).to be_nil
      expect(attrs.is_read_only).to be_nil
      expect(attrs.tags).to be_nil
    end
  end

  describe 'DashboardJsonAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::DashboardJsonAttributes }

    it 'constructs with dashboard string' do
      attrs = klass.new(dashboard: '{"title":"test"}')
      expect(attrs.dashboard).to eq('{"title":"test"}')
    end
  end

  describe 'SyntheticsTestAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::SyntheticsTestAttributes }

    it 'constructs with required attributes' do
      attrs = klass.new(name: 'C', type: 'api', status: 'live', locations: ['aws:us-east-1'])
      expect(attrs.name).to eq('C')
      expect(attrs.locations).to eq(['aws:us-east-1'])
    end

    it 'sets optional config/options/subtype to nil by default' do
      attrs = klass.new(name: 'C', type: 'api', status: 'live', locations: ['loc1'])
      expect(attrs.config).to be_nil
      expect(attrs.options).to be_nil
      expect(attrs.subtype).to be_nil
      expect(attrs.message).to be_nil
    end
  end

  describe 'ServiceLevelObjectiveAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::ServiceLevelObjectiveAttributes }

    it 'constructs with required attributes' do
      attrs = klass.new(name: 'SLO', type: 'metric', thresholds: '99.9')
      expect(attrs.name).to eq('SLO')
      expect(attrs.type).to eq('metric')
      expect(attrs.thresholds).to eq('99.9')
    end

    it 'sets optional target_threshold and warning_threshold to nil by default' do
      attrs = klass.new(name: 'SLO', type: 'metric', thresholds: '99.9')
      expect(attrs.target_threshold).to be_nil
      expect(attrs.warning_threshold).to be_nil
      expect(attrs.monitor_ids).to be_nil
    end

    it 'accepts float thresholds' do
      attrs = klass.new(
        name: 'SLO', type: 'metric', thresholds: '99.9',
        target_threshold: 99.5, warning_threshold: 99.8
      )
      expect(attrs.target_threshold).to eq(99.5)
      expect(attrs.warning_threshold).to eq(99.8)
    end
  end

  describe 'LogsIndexAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::LogsIndexAttributes }

    it 'constructs with required attributes' do
      attrs = klass.new(name: 'main', filter: 'source:app')
      expect(attrs.name).to eq('main')
      expect(attrs.filter).to eq('source:app')
    end

    it 'accepts daily_limit_warning_threshold_percentage as float' do
      attrs = klass.new(name: 'main', filter: 'f', daily_limit_warning_threshold_percentage: 80.5)
      expect(attrs.daily_limit_warning_threshold_percentage).to eq(80.5)
    end
  end

  describe 'LogsPipelineAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::LogsPipelineAttributes }

    it 'constructs with required attributes' do
      attrs = klass.new(name: 'p', filter: 'source:nginx')
      expect(attrs.name).to eq('p')
      expect(attrs.filter).to eq('source:nginx')
    end

    it 'sets is_enabled to nil by default' do
      attrs = klass.new(name: 'p', filter: 'f')
      expect(attrs.is_enabled).to be_nil
    end
  end

  describe 'LogsMetricAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::LogsMetricAttributes }

    it 'constructs with required attributes' do
      attrs = klass.new(name: 'err', compute: 'count')
      expect(attrs.name).to eq('err')
      expect(attrs.compute).to eq('count')
    end
  end

  describe 'ApmRetentionFilterAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::ApmRetentionFilterAttributes }

    it 'constructs with required attributes' do
      attrs = klass.new(name: 'f', enabled: true, filter_type: 'spans-errors-sampling-processor', rate: 1.0)
      expect(attrs.name).to eq('f')
      expect(attrs.enabled).to eq(true)
      expect(attrs.filter_type).to eq('spans-errors-sampling-processor')
      expect(attrs.rate).to eq(1.0)
    end

    it 'handles rate at boundary values' do
      attrs_zero = klass.new(name: 'f', enabled: true, filter_type: 'spans-sampling-processor', rate: 0.0)
      expect(attrs_zero.rate).to eq(0.0)

      attrs_one = klass.new(name: 'f', enabled: true, filter_type: 'spans-sampling-processor', rate: 1.0)
      expect(attrs_one.rate).to eq(1.0)
    end
  end

  describe 'IntegrationAwsAttributes' do
    let(:klass) { Pangea::Resources::Datadog::Types::IntegrationAwsAttributes }

    it 'constructs with required account_id' do
      attrs = klass.new(account_id: '123456789012')
      expect(attrs.account_id).to eq('123456789012')
    end

    it 'sets all optional fields to nil by default' do
      attrs = klass.new(account_id: '123456789012')
      expect(attrs.access_key_id).to be_nil
      expect(attrs.role_name).to be_nil
      expect(attrs.secret_access_key).to be_nil
      expect(attrs.cspm_resource_collection_enabled).to be_nil
      expect(attrs.metrics_collection_enabled).to be_nil
      expect(attrs.resource_collection_enabled).to be_nil
      expect(attrs.excluded_regions).to be_nil
      expect(attrs.filter_tags).to be_nil
      expect(attrs.host_tags).to be_nil
    end
  end
end
