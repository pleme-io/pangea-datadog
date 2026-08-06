# frozen_string_literal: true

require_relative 'normalize'

module Pangea
  module Datadog
    module Absorb
      # The org-specific decisions, resolved from config.
      #
      # Every judgement that used to be a constant in classify.rb or emit.rb now
      # arrives here as data. Construct Rules with no config and it makes the
      # minimum possible judgement: nothing is retired except a dashboard with no
      # widgets, nothing is frozen, no monitor is grouped, no archetype matches.
      # That default matters -- it is what proves the engine carries no
      # organisation's policy of its own.
      class Rules
        Archetype = Struct.new(:name, :engine, :group_by, :widgets, :defaults, :pattern, keyword_init: true) do
          # Named captures in the match pattern become the instance's parameters,
          # so a config author decides what varies without touching Ruby.
          def params_for(title)
            m = pattern.match(title.to_s)
            return nil unless m

            m.names.each_with_object({}) { |n, h| h[n.to_sym] = m[n] }
          end
        end

        EMPTY = {
          provenance: [],
          retire_patterns: [],
          retire_empty: true,
          dedupe: false,
          repair: { enabled: false, list_repr: true, separator_space: true },
          group_tag: nil,
          group_fallback: 'unclassified',
          template_prefix: 'pangea_datadog',
          archetypes: []
        }.freeze

        def self.none
          new(nil)
        end

        def self.from(config)
          new(config)
        end

        def initialize(config)
          @config = config
          @rules = config ? build(config) : EMPTY
        end

        # ---- provenance ---------------------------------------------------

        # Returns the configured rule name, or nil when nothing matches and the
        # config declared no terminal default (Config#validate! forbids that, so
        # nil here means Rules was built with no config at all).
        def provenance_of(payload)
          tags = Array(payload['tags'])
          @rules[:provenance].each do |rule|
            return rule[:name] if match_provenance?(rule[:match], tags)
          end
          nil
        end

        def disposition_of(name)
          rule = @rules[:provenance].find { |r| r[:name] == name }
          rule ? rule[:disposition] : 'adopt'
        end

        def adopt?(payload)
          disposition_of(provenance_of(payload)) == 'adopt'
        end

        def frozen?(payload)
          disposition_of(provenance_of(payload)) == 'frozen'
        end

        # ---- tags ---------------------------------------------------------

        # Two defects seen in real estates, each switchable independently:
        # a Python list repr written into the tags array, and a space after the
        # tag separator (which Datadog treats as a different tag).
        def repair_tags(tags)
          list  = @rules[:repair][:list_repr]
          space = @rules[:repair][:separator_space]
          values = Array(tags)
          joined = values.join(',')

          if list && (joined.include?('[') || joined.include?("'"))
            values = joined.gsub(/\A\[/, '').gsub(/\]\z/, '').split(',')
                           .map { |t| t.strip.gsub(/\A['"]|['"]\z/, '') }
                           .reject(&:empty?)
          end

          space ? values.map { |t| normalize_separator(t) } : values
        end

        def repair_on_emit? = @rules[:repair][:enabled]

        def normalize_separator(tag)
          key, value = tag.to_s.split(':', 2)
          return tag.to_s.strip if value.nil?

          "#{key.strip}:#{value.strip}"
        end

        # ---- dashboards ---------------------------------------------------

        # The emitted shard's template name prefix.
        #
        # This was hardcoded to one organisation's name in emit.rb, so every
        # shard this engine produced for ANY estate carried that customer's
        # name. The engine is otherwise general -- a second
        # shipped config exists precisely to prove that -- and a hardcoded
        # customer name in generated output is both a generality bug and, in a
        # public gem, someone else's name in our source.
        def template_prefix = @rules[:template_prefix]

        def retire_empty? = @rules[:retire_empty]
        def dedupe_identical? = @rules[:dedupe]

        def retire_title?(title)
          @rules[:retire_patterns].any? { |p| p.match?(title.to_s) }
        end

        # ---- grouping -----------------------------------------------------

        def group_for(payload)
          tag = @rules[:group_tag]
          return @rules[:group_fallback] unless tag

          prefix = "#{tag}:"
          hit = repair_tags(payload['tags']).find { |t| t.to_s.start_with?(prefix) }
          return @rules[:group_fallback] unless hit

          slug = hit.split(':', 2).last.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
          slug.empty? ? @rules[:group_fallback] : slug
        end

        # ---- archetypes ---------------------------------------------------

        def archetype_for(title)
          @rules[:archetypes].find { |a| a.pattern.match?(title.to_s) }
        end

        def archetypes = @rules[:archetypes]

        private

        def match_provenance?(match, tags)
          return true if match['default']
          return tags.empty? if match.key?('no_tags') && match['no_tags']

          if (needle = match['tag'])
            return tags.any? { |t| t.to_s.include?(needle) }
          end

          if (prefix = match['tag_prefix'])
            return tags.any? { |t| t.to_s.start_with?(prefix) }
          end

          false
        end

        def build(config)
          {
            provenance: config.provenance_rules.map do |r|
              { name: r['name'], disposition: r['disposition'], match: r['match'] || {} }
            end,
            retire_patterns: config.retire_title_patterns,
            retire_empty: config.retire_empty_widgets?,
            dedupe: config.dedupe_identical?,
            repair: {
              enabled: config.repair_tags?,
              list_repr: config.strip_list_repr?,
              separator_space: config.strip_separator_space?
            },
            group_tag: config.monitors_group_tag,
            group_fallback: config.group_fallback,
            template_prefix: config.template_prefix,
            archetypes: config.archetypes.map do |a|
              Archetype.new(
                name: a['name'],
                engine: a['engine'],
                group_by: a['group_by'],
                widgets: a['widgets'],
                defaults: a['defaults'] || {},
                pattern: Regexp.new(a.dig('match', 'title'))
              )
            end
          }
        end
      end
    end
  end
end
