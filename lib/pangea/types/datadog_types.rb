# frozen_string_literal: true

require 'dry-types'
require 'pangea/resources/types'

module Pangea
  module Resources
    module Datadog
      # Provider-specific Dry::Types for Datadog resources.
      # Individual resource types.rb files define Dry::Struct classes that
      # reference these via T = Pangea::Resources::Datadog::Types.
      module Types
        include Dry.Types()

        T = ::Pangea::Resources::Types

        # Monitor types
        MonitorType = T::String.constrained(
          included_in: %w[
            metric\ alert service\ check event\ alert event-v2\ alert
            query\ alert composite log\ alert trace-analytics\ alert
            slo\ alert rum\ alert ci-pipelines\ alert ci-tests\ alert
            audit\ alert error-tracking\ alert database-monitoring\ alert
          ]
        )

        # Dashboard layout types
        DashboardLayoutType = T::String.constrained(
          included_in: %w[ordered free]
        )

        # Dashboard reflow types
        DashboardReflowType = T::String.constrained(
          included_in: %w[auto fixed]
        )

        # Synthetics test types
        SyntheticsTestType = T::String.constrained(
          included_in: %w[api browser mobile]
        )

        # Synthetics test subtypes
        SyntheticsSubtype = T::String.constrained(
          included_in: %w[http ssl tcp dns icmp udp websocket grpc multi]
        )

        # Synthetics test status
        SyntheticsStatus = T::String.constrained(
          included_in: %w[live paused]
        )

        # SLO types
        SloType = T::String.constrained(
          included_in: %w[metric monitor time_slice]
        )

        # SLO timeframes
        SloTimeframe = T::String.constrained(
          included_in: %w[7d 30d 90d custom]
        )

        # APM retention filter types
        ApmRetentionFilterType = T::String.constrained(
          included_in: %w[
            spans-sampling-processor
            spans-errors-sampling-processor
            spans-appsec-sampling-processor
          ]
        )
      end
    end
  end
end
