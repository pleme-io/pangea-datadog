# frozen_string_literal: true

require 'json'
require 'set'

module Pangea
  module Datadog
    module Absorb
      # Does the code absorb emits conform to the provider's own schema?
      #
      # THE ORACLE THIS FILLS IN. verify proves code-vs-estate by comparing
      # attributes, and it is blind to whether the provider will accept those
      # attributes at all -- it compares absorb's output against absorb's own
      # idea of what the output should be. roundtrip answers the real question,
      # but it needs live credentials, a realised provider mirror and about an
      # hour for the full estate. So the fast oracle could not see provider
      # drift and the slow one was too expensive to run on every change.
      #
      # This is offline, needs no credentials, and runs in seconds, because the
      # provider ships its own schema and `terraform providers schema -json`
      # prints it. It cannot replace roundtrip -- a body can be perfectly
      # schema-conformant and still be refused for a semantic reason, which is
      # exactly what happened with restricted role permissions, where every
      # attribute was valid and the provider still would not plan it. What it
      # catches is the class roundtrip is too slow to catch early: a provider
      # upgrade that renames, removes or re-classifies an attribute.
      #
      # IT WALKS THE WHOLE BODY, not just the top level. The deepest emitted
      # bodies on this estate reach seven levels
      # (widget.timeseries_definition.request.query.metric_query), 58 distinct
      # nested paths in all, and every level is produced by hand-written
      # normalizer or archetype-engine code. A top-level-only check would
      # declare the entire widget tree conformant without looking at any of it.
      #
      # THREE CHECKS, and each one is a different way to be wrong:
      #
      #   undeclared        an emitted key the provider does not declare.
      #                     terraform rejects the config outright.
      #   missing_required  a required attribute absent from the body.
      #                     terraform rejects the config outright.
      #   computed_only     a key the provider computes and does not accept.
      #                     terraform rejects it as not-configurable.
      #
      # `skipped` is the fourth outcome and is not a pass. A resource type the
      # schema does not declare cannot be checked, and reporting it as conformant
      # would mean a provider downgrade silently stopped checking a whole type.
      module Conform
        Error = Class.new(StandardError)

        Finding = Struct.new(:type, :key, :ids, keyword_init: true)

        Result = Struct.new(:checked, :undeclared, :missing_required, :computed_only, :skipped,
                            :nested_paths, keyword_init: true) do
          def ok? = undeclared.empty? && missing_required.empty? && computed_only.empty?

          def findings
            {
              'checked' => checked,
              'undeclared' => undeclared.size,
              'missingRequired' => missing_required.size,
              'computedOnly' => computed_only.size,
              'skippedTypes' => skipped,
              'nestedPathsChecked' => nested_paths,
              'detail' => (undeclared + missing_required + computed_only).map do |f|
                { 'type' => f.type, 'key' => f.key, 'objects' => f.ids.size }
              end
            }
          end

          def to_s
            lines = ["conform: #{checked} bodies checked against the provider schema, " \
                     "#{undeclared.size} undeclared, #{missing_required.size} missing required, " \
                     "#{computed_only.size} computed-only",
                     "  #{nested_paths} distinct nested block paths reached"]
            undeclared.each do |f|
              lines << "  UNDECLARED #{f.type}.#{f.key} on #{f.ids.size} objects " \
                       "(e.g. #{f.ids.first}) -- the provider does not declare it"
            end
            missing_required.each do |f|
              lines << "  MISSING #{f.type}.#{f.key} on #{f.ids.size} objects " \
                       "(e.g. #{f.ids.first}) -- the provider requires it"
            end
            computed_only.each do |f|
              lines << "  COMPUTED-ONLY #{f.type}.#{f.key} on #{f.ids.size} objects " \
                       "(e.g. #{f.ids.first}) -- the provider computes it and will not accept it"
            end
            skipped.each do |type|
              lines << "  SKIPPED #{type} is not in this schema -- NOT checked, not conformant"
            end
            lines.join("\n")
          end
        end

        # terraform accepts these on any resource; they are not part of a
        # resource's own schema and their absence from it means nothing.
        META_ARGUMENTS = %w[lifecycle depends_on count for_each provider].freeze

        module_function

        def run(capture:, schema_path:, rules: nil)
          schema = load_schema(schema_path)
          roundtrip = Roundtrip.new(capture: capture, provider_dir: NO_PROVIDER_NEEDED, rules: rules)

          sink = { undeclared: Hash.new { |h, k| h[k] = [] },
                   missing: Hash.new { |h, k| h[k] = [] },
                   computed: Hash.new { |h, k| h[k] = [] },
                   paths: Set.new }
          skipped = []
          checked = 0

          Roundtrip::KINDS.each do |kind, spec|
            type = spec[:resource]
            block = schema.dig(type, 'block')
            next skipped << type if block.nil?

            checked += check_kind(roundtrip, capture, kind, spec, type, block, sink)
          end

          Result.new(checked: checked, undeclared: findings_for(sink[:undeclared]),
                     missing_required: findings_for(sink[:missing]),
                     computed_only: findings_for(sink[:computed]),
                     skipped: skipped.uniq.sort, nested_paths: sink[:paths].size)
        end

        # body_for needs no provider binary -- it only normalizes a payload --
        # so conform stays offline. Naming the constant says that is deliberate
        # rather than a path someone forgot to fill in.
        NO_PROVIDER_NEEDED = '/nonexistent'

        def check_kind(roundtrip, capture, kind, spec, type, block, sink)
          count = 0
          capture.ids(spec[:capture]).each do |id|
            body = body_for(roundtrip, kind, capture.read(spec[:capture], id), id)
            next if body.nil?

            count += 1
            walk(body, block, [], type, id, sink)
          end
          count
        rescue Errno::ENOENT
          0
        end

        # Recursive, because the top level is the shallow end. The deepest
        # emitted bodies on this estate reach seven levels
        # (widget.timeseries_definition.request.query.metric_query), and every
        # one of those levels is produced by hand-written normalizer or
        # archetype-engine code. A top-level-only check would have declared the
        # whole widget tree conformant without looking at any of it.
        def walk(body, block, path, type, id, sink)
          attributes = block['attributes'] || {}
          blocks = block['block_types'] || {}
          # Meta-arguments are accepted on a RESOURCE, not inside a block, so
          # they are only legal at the top level.
          declared = attributes.keys + blocks.keys + (path.empty? ? META_ARGUMENTS : [])
          required = attributes.select { |_, v| v['required'] }.keys
          computed_only = attributes.select do |_, v|
            v['computed'] && !v['optional'] && !v['required']
          end.keys

          keys = body.keys.map(&:to_s)
          (keys - declared).each { |k| sink[:undeclared]["#{type}\0#{join(path, k)}"] << id }
          (required - keys).each { |k| sink[:missing]["#{type}\0#{join(path, k)}"] << id }
          (keys & computed_only).each { |k| sink[:computed]["#{type}\0#{join(path, k)}"] << id }

          body.each do |key, value|
            nested = blocks[key.to_s]
            next if nested.nil? || nested['block'].nil?

            # A block arrives either as one Hash or as a list of them, and
            # `Array(hash)` does NOT give [hash] -- it gives the hash's pairs,
            # which are Arrays. Relying on it silently skipped every
            # Hash-valued block: monitor_thresholds on 231 monitors was
            # registered as a reached path and then never descended into. The
            # count said covered while nothing had been checked.
            children = children_of(value)
            next if children.empty?

            child = path + [key.to_s]
            sink[:paths] << child.join('.')
            children.each { |item| walk(item, nested['block'], child, type, id, sink) }
          end
        end

        def join(path, key) = (path + [key]).join('.')

        def children_of(value)
          case value
          when Hash then [value]
          when Array then value.select { |item| item.is_a?(Hash) }
          else []
          end
        end

        # A kind that cannot produce a body for one object says nothing about
        # the provider schema -- it is an absorb-side gap, and verify's own
        # coverage check is what reports it. Skipping keeps this oracle about
        # conformance rather than turning it into a second, worse coverage check.
        def body_for(roundtrip, kind, payload, id)
          roundtrip.body_for(kind, payload, id)
        rescue StandardError
          nil
        end

        def findings_for(collected)
          collected.map do |composite, ids|
            type, key = composite.split("\0", 2)
            Finding.new(type: type, key: key, ids: ids)
          end.sort_by { |f| [f.type, f.key] }
        end

        def load_schema(path)
          schemas = JSON.parse(File.read(path))['provider_schemas']
          raise Error, "#{path} holds no provider_schemas" unless schemas.is_a?(Hash)

          schemas.values.each_with_object({}) do |entry, all|
            all.merge!(entry['resource_schemas'] || {})
          end
        rescue JSON::ParserError => e
          raise Error, "#{path} is not valid JSON: #{e.message}"
        end
      end
    end
  end
end
