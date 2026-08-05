# frozen_string_literal: true

require_relative 'normalize'
require_relative 'rules'

module Pangea
  module Datadog
    module Absorb
      # Decides what each absorbed object is and what should happen to it.
      #
      # Every judgement here is delegated to Rules, which is built from config.
      # This file used to carry one organisation's regexes and tag conventions as
      # constants; it now carries none, and what remains is mechanism: recursion
      # over a capture, content fingerprinting, and the tier vocabulary.
      #
      # Absorbing an estate faithfully is not the same as adopting all of it. On
      # one real estate 79 of 149 dashboards were scratch, clones, tests or empty.
      # Emitting those as infrastructure code encodes the mess rather than
      # representing the system, so classification runs before emission and the
      # retire tier is never authored. Which dashboards those are, though, is a
      # question only that estate's config can answer.
      module Classify
        module_function

        TIER_ADOPT     = :adopt
        TIER_ARCHETYPE = :archetype
        TIER_RETIRE    = :retire

        # ---- monitors ----------------------------------------------------

        # Provenance decides ownership, and ownership decides whether a monitor
        # may be declared here at all. A monitor already managed by another IaC
        # system must not be re-declared; two writers on one object is the bug.
        def monitor_provenance(payload, rules:)
          rules.provenance_of(payload)
        end

        def adopt_monitor?(payload, rules:)
          rules.adopt?(payload)
        end

        # Generic defect detection: a tag list carrying a serialized list repr.
        # Detecting it needs no config; deciding whether to repair it does.
        def tags_corrupted?(payload)
          Array(payload['tags']).any? { |t| t.to_s.start_with?('[') || t.to_s.end_with?(']') }
        end

        # ---- dashboards --------------------------------------------------

        # `twins` maps a content fingerprint to every id sharing it, so a clone is
        # identified by what it contains rather than by whether somebody left
        # "(cloned)" in the title.
        def dashboard_tier(payload, id:, rules:, twins: {})
          return TIER_RETIRE if rules.retire_empty? && Array(payload['widgets']).empty?

          title = payload['title'].to_s
          return TIER_RETIRE if rules.retire_title?(title)

          if rules.dedupe_identical?
            siblings = twins[Normalize.fingerprint(Normalize.dashboard(payload))] || [id]
            return TIER_RETIRE if siblings.size > 1 && siblings.first != id
          end

          return TIER_ARCHETYPE if rules.archetype_for(title)

          TIER_ADOPT
        end

        # Build the fingerprint index a tier decision needs. Ids are sorted so the
        # surviving member of a clone set is stable across runs.
        def twin_index(capture)
          index = Hash.new { |h, k| h[k] = [] }
          capture.each(:dashboards) do |id, payload|
            index[Normalize.fingerprint(Normalize.dashboard(payload))] << id
          end
          index.each_value(&:sort!)
          index
        end
      end
    end
  end
end
