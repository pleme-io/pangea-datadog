# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Pangea::Resources::Datadog::Types' do
  let(:types) { Pangea::Resources::Datadog::Types }

  describe 'MonitorType' do
    it 'accepts valid monitor types' do
      %w[metric\ alert service\ check event\ alert query\ alert composite log\ alert].each do |t|
        expect(types::MonitorType[t]).to eq(t)
      end
    end

    it 'accepts all documented monitor types' do
      all_types = %w[
        metric\ alert service\ check event\ alert event-v2\ alert
        query\ alert composite log\ alert trace-analytics\ alert
        slo\ alert rum\ alert ci-pipelines\ alert ci-tests\ alert
        audit\ alert error-tracking\ alert database-monitoring\ alert
      ]
      all_types.each do |t|
        expect { types::MonitorType[t] }.not_to raise_error
      end
    end

    it 'rejects invalid monitor type' do
      expect { types::MonitorType['invalid_type'] }.to raise_error(Dry::Types::ConstraintError)
    end

    it 'rejects empty string' do
      expect { types::MonitorType[''] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe 'DashboardLayoutType' do
    it 'accepts ordered layout' do
      expect(types::DashboardLayoutType['ordered']).to eq('ordered')
    end

    it 'accepts free layout' do
      expect(types::DashboardLayoutType['free']).to eq('free')
    end

    it 'rejects invalid layout type' do
      expect { types::DashboardLayoutType['grid'] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe 'DashboardReflowType' do
    it 'accepts auto reflow' do
      expect(types::DashboardReflowType['auto']).to eq('auto')
    end

    it 'accepts fixed reflow' do
      expect(types::DashboardReflowType['fixed']).to eq('fixed')
    end

    it 'rejects invalid reflow type' do
      expect { types::DashboardReflowType['responsive'] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe 'SyntheticsTestType' do
    it 'accepts api type' do
      expect(types::SyntheticsTestType['api']).to eq('api')
    end

    it 'accepts browser type' do
      expect(types::SyntheticsTestType['browser']).to eq('browser')
    end

    it 'accepts mobile type' do
      expect(types::SyntheticsTestType['mobile']).to eq('mobile')
    end

    it 'rejects invalid type' do
      expect { types::SyntheticsTestType['grpc'] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe 'SyntheticsSubtype' do
    it 'accepts all valid subtypes' do
      %w[http ssl tcp dns icmp udp websocket grpc multi].each do |s|
        expect(types::SyntheticsSubtype[s]).to eq(s)
      end
    end

    it 'rejects invalid subtype' do
      expect { types::SyntheticsSubtype['ftp'] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe 'SyntheticsStatus' do
    it 'accepts live status' do
      expect(types::SyntheticsStatus['live']).to eq('live')
    end

    it 'accepts paused status' do
      expect(types::SyntheticsStatus['paused']).to eq('paused')
    end

    it 'rejects invalid status' do
      expect { types::SyntheticsStatus['stopped'] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe 'SloType' do
    it 'accepts metric type' do
      expect(types::SloType['metric']).to eq('metric')
    end

    it 'accepts monitor type' do
      expect(types::SloType['monitor']).to eq('monitor')
    end

    it 'accepts time_slice type' do
      expect(types::SloType['time_slice']).to eq('time_slice')
    end

    it 'rejects invalid SLO type' do
      expect { types::SloType['percentage'] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe 'SloTimeframe' do
    it 'accepts all valid timeframes' do
      %w[7d 30d 90d custom].each do |tf|
        expect(types::SloTimeframe[tf]).to eq(tf)
      end
    end

    it 'rejects invalid timeframe' do
      expect { types::SloTimeframe['1d'] }.to raise_error(Dry::Types::ConstraintError)
    end

    it 'rejects empty string' do
      expect { types::SloTimeframe[''] }.to raise_error(Dry::Types::ConstraintError)
    end
  end

  describe 'ApmRetentionFilterType' do
    it 'accepts spans-sampling-processor' do
      expect(types::ApmRetentionFilterType['spans-sampling-processor']).to eq('spans-sampling-processor')
    end

    it 'accepts spans-errors-sampling-processor' do
      expect(types::ApmRetentionFilterType['spans-errors-sampling-processor']).to eq('spans-errors-sampling-processor')
    end

    it 'accepts spans-appsec-sampling-processor' do
      expect(types::ApmRetentionFilterType['spans-appsec-sampling-processor']).to eq('spans-appsec-sampling-processor')
    end

    it 'rejects invalid filter type' do
      expect { types::ApmRetentionFilterType['custom-processor'] }.to raise_error(Dry::Types::ConstraintError)
    end

    it 'rejects partial match' do
      expect { types::ApmRetentionFilterType['spans-sampling'] }.to raise_error(Dry::Types::ConstraintError)
    end
  end
end
