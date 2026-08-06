# frozen_string_literal: true

require 'yaml'

module Pangea
  module Datadog
    module Absorb
      # The typed config that makes the engine general.
      #
      # Everything specific to one organisation's Datadog estate lives here as
      # data: which account, which provenance rules decide ownership, what counts
      # as a retirable dashboard, how monitors are grouped, and which archetypes
      # exist. The engine itself knows none of it.
      #
      # What deliberately does NOT come from config: the API-to-provider
      # projection in Normalize. That is a fact about the Terraform datadog
      # provider, identical for every organisation, and making it configurable
      # would invite a user to describe the provider incorrectly.
      #
      # Pattern follows the org's live keyway reference implementation, the
      # live merged keyway reference:
      #
      #   read -> strict decode -> validate -> return, one entry point
      #   unknown keys are a HARD ERROR
      #   defaults applied in one place
      #   errors name the field and the value seen
      #
      # Ruby's YAML has no KnownFields equivalent, so the strictness is built by
      # hand below. Without it a typo'd key is silently ignored and the config
      # lies about what it is doing, which defeats the whole point.
      class Config
        Error = Class.new(StandardError)

        DISPOSITIONS = %w[adopt frozen ignore].freeze

        SCHEMA = {
          'site' => :string,
          'account' => :string,
          'template_prefix' => :string,
          'credentials' => {
            'source' => :string,
            'dir' => :string,
            'api_key_file' => :string,
            'app_key_file' => :string,
            'sops_file' => :string,
            'sops_nix_dir' => :string,
            'api_key_secret' => :string,
            'app_key_secret' => :string
          },
          'provenance' => :array,
          'retire' => {
            'empty_widgets' => :bool,
            'title_patterns' => :array,
            'duplicate_content' => :string
          },
          'grouping' => {
            'monitors_by_tag' => :string,
            'fallback' => :string
          },
          'tag_repair' => {
            'enabled' => :bool,
            'strip_list_repr' => :bool,
            'strip_separator_space' => :bool
          },
          'archetypes' => :array,
          'exclude' => {
            'monitor_ids' => :array,
            'dashboard_ids' => :array
          }
        }.freeze

        DEFAULTS = {
          'site' => 'datadoghq.com',
          'credentials' => {
            'source' => 'sops',
            'dir' => nil,
            'api_key_file' => 'api-key',
            'app_key_file' => 'app-key',
            'sops_file' => nil,
            'sops_nix_dir' => nil,
            'api_key_secret' => nil,
            'app_key_secret' => nil
          },
          'retire' => {
            'empty_widgets' => true,
            'title_patterns' => [],
            'duplicate_content' => 'keep_first'
          },
          'grouping' => {
            'monitors_by_tag' => nil,
            'fallback' => 'unclassified'
          },
          'tag_repair' => {
            'enabled' => false,
            'strip_list_repr' => true,
            'strip_separator_space' => true
          },
          'archetypes' => [],
          'exclude' => { 'monitor_ids' => [], 'dashboard_ids' => [] }
        }.freeze

        attr_reader :path, :raw

        def self.load(path)
          raise Error, "config not found: #{path}" unless File.readable?(path)

          parsed = begin
            YAML.safe_load(File.read(path), aliases: true)
          rescue Psych::SyntaxError => e
            raise Error, "config #{path}: #{e.message}"
          end
          raise Error, "config #{path}: expected a mapping at the top level" unless parsed.is_a?(Hash)

          new(parsed, path: path).tap(&:validate!)
        end

        def initialize(raw, path: '(inline)')
          @path = path
          @raw  = deep_merge(DEFAULTS, raw || {})
        end

        # ---- accessors ----------------------------------------------------

        def site = fetch('site')
        def account = fetch('account')

        def credential_dir
          dir = dig('credentials', 'dir')
          dir || File.join(Dir.home, '.config', 'datadog', account.to_s)
        end

        def api_key_path = File.join(credential_dir, dig('credentials', 'api_key_file'))
        def app_key_path = File.join(credential_dir, dig('credentials', 'app_key_file'))

        # sops is the fleet default. The secret PATH convention matches what the
        # nix profiles already declare (api_key_secret = "datadog/<org>/api-key"
        # in profiles/darwin-developer/home/default.nix), so one name is used by
        # the deployer and the consumer rather than two that must be kept in sync.
        def credential_source = dig('credentials', 'source')
        def sops? = credential_source == 'sops'
        def sops_file = dig('credentials', 'sops_file')
        def sops_nix_dir = dig('credentials', 'sops_nix_dir')

        def api_key_secret
          dig('credentials', 'api_key_secret') || "datadog/#{account}/api-key"
        end

        def app_key_secret
          dig('credentials', 'app_key_secret') || "datadog/#{account}/app-key"
        end

        def provenance_rules = fetch('provenance')
        def archetypes = fetch('archetypes')

        def retire_empty_widgets? = dig('retire', 'empty_widgets')
        def retire_title_patterns = dig('retire', 'title_patterns').map { |p| Regexp.new(p) }
        def dedupe_identical? = dig('retire', 'duplicate_content') == 'keep_first'

        def monitors_group_tag = dig('grouping', 'monitors_by_tag')
        def group_fallback = dig('grouping', 'fallback')

        # The prefix for emitted shard template names. Defaults to something
        # org-neutral: this engine ships in a public gem and must not carry one
        # organisation's name in the code it generates. It was hardcoded, so
        # every shard emitted for ANY estate was named for a single customer.
        DEFAULT_TEMPLATE_PREFIX = 'pangea_datadog'

        def template_prefix
          value = @raw['template_prefix']
          value.nil? || value.to_s.empty? ? DEFAULT_TEMPLATE_PREFIX : value.to_s
        end

        def repair_tags? = dig('tag_repair', 'enabled')
        def strip_list_repr? = dig('tag_repair', 'strip_list_repr')
        def strip_separator_space? = dig('tag_repair', 'strip_separator_space')

        def excluded_monitor?(id) = dig('exclude', 'monitor_ids').map(&:to_s).include?(id.to_s)
        def excluded_dashboard?(id) = dig('exclude', 'dashboard_ids').map(&:to_s).include?(id.to_s)

        # Provenance dispositions the emitter should actually write.
        def emitted_provenance
          provenance_rules.select { |r| r['disposition'] == 'adopt' }.map { |r| r['name'] }
        end

        def frozen_provenance
          provenance_rules.select { |r| r['disposition'] == 'frozen' }.map { |r| r['name'] }
        end

        # ---- validation ---------------------------------------------------

        def validate!
          reject_unknown!(@raw, SCHEMA, 'config')
          require_present!('account')
          validate_provenance!
          validate_retire!
          validate_archetypes!
          self
        end

        private

        def validate_provenance!
          rules = fetch('provenance')
          raise Error, "config #{path}: provenance must have at least one rule" if !rules.is_a?(Array) || rules.empty?

          seen = {}
          rules.each_with_index do |rule, i|
            raise Error, "config #{path}: provenance[#{i}] must be a mapping" unless rule.is_a?(Hash)

            reject_unknown!(rule, { 'name' => :string, 'disposition' => :string, 'match' => :hash },
                            "provenance[#{i}]")
            name = rule['name']
            raise Error, "config #{path}: provenance[#{i}].name is required" if blank?(name)
            raise Error, "config #{path}: duplicate provenance name #{name.inspect}" if seen[name]

            seen[name] = true

            disp = rule['disposition']
            unless DISPOSITIONS.include?(disp)
              raise Error, "config #{path}: provenance #{name.inspect}: disposition must be one of " \
                           "#{DISPOSITIONS.join(', ')}, got #{disp.inspect}"
            end

            validate_match!(rule['match'], name, i)
          end

          return if rules.any? { |r| (r['match'] || {})['default'] }

          raise Error, "config #{path}: provenance needs a terminal rule with `match: {default: true}` " \
                       'or a monitor matching nothing would be unclassified'
        end

        MATCH_KEYS = { 'tag' => :string, 'tag_prefix' => :string, 'no_tags' => :bool, 'default' => :bool }.freeze

        def validate_match!(match, name, index)
          raise Error, "config #{path}: provenance #{name.inspect}: match is required" unless match.is_a?(Hash)

          reject_unknown!(match, MATCH_KEYS, "provenance[#{index}].match")
          return unless match.keys.empty?

          raise Error, "config #{path}: provenance #{name.inspect}: match must carry one of " \
                       "#{MATCH_KEYS.keys.join(', ')}"
        end

        def validate_retire!
          dig('retire', 'title_patterns').each_with_index do |pattern, i|
            Regexp.new(pattern)
          rescue RegexpError => e
            raise Error, "config #{path}: retire.title_patterns[#{i}] is not a valid regexp: #{e.message}"
          end

          mode = dig('retire', 'duplicate_content')
          return if %w[keep_first keep_all].include?(mode)

          raise Error, "config #{path}: retire.duplicate_content must be keep_first or keep_all, got #{mode.inspect}"
        end

        ARCHETYPE_KEYS = {
          'name' => :string, 'match' => :hash, 'engine' => :string,
          'group_by' => :string, 'widgets' => :array, 'defaults' => :hash
        }.freeze

        def validate_archetypes!
          seen = {}
          fetch('archetypes').each_with_index do |arch, i|
            raise Error, "config #{path}: archetypes[#{i}] must be a mapping" unless arch.is_a?(Hash)

            reject_unknown!(arch, ARCHETYPE_KEYS, "archetypes[#{i}]")
            name = arch['name']
            raise Error, "config #{path}: archetypes[#{i}].name is required" if blank?(name)
            raise Error, "config #{path}: duplicate archetype name #{name.inspect}" if seen[name]

            seen[name] = true

            raise Error, "config #{path}: archetype #{name.inspect}: engine is required" if blank?(arch['engine'])

            title = (arch['match'] || {})['title']
            raise Error, "config #{path}: archetype #{name.inspect}: match.title is required" if blank?(title)

            begin
              Regexp.new(title)
            rescue RegexpError => e
              raise Error, "config #{path}: archetype #{name.inspect}: match.title is not a valid regexp: #{e.message}"
            end

            widgets = arch['widgets']
            if !widgets.is_a?(Array) || widgets.empty?
              raise Error, "config #{path}: archetype #{name.inspect}: widgets must be a non-empty list"
            end

            widgets.each_with_index { |w, j| validate_widget!(w, name, j) }
          end
        end

        WIDGET_KEYS = { 'metric' => :string, 'query' => :string, 'legend' => :string, 'layout' => :hash }.freeze
        LAYOUT_KEYS = %w[x y width height].freeze

        def validate_widget!(widget, arch, index)
          unless widget.is_a?(Hash)
            raise Error, "config #{path}: archetype #{arch.inspect}: widgets[#{index}] must be a mapping"
          end

          reject_unknown!(widget, WIDGET_KEYS, "archetype #{arch}: widgets[#{index}]")
          %w[metric query legend].each do |key|
            next unless blank?(widget[key])

            raise Error, "config #{path}: archetype #{arch.inspect}: widgets[#{index}].#{key} is required"
          end

          layout = widget['layout']
          unless layout.is_a?(Hash)
            raise Error, "config #{path}: archetype #{arch.inspect}: widgets[#{index}].layout is required"
          end

          missing = LAYOUT_KEYS - layout.keys
          return if missing.empty?

          raise Error, "config #{path}: archetype #{arch.inspect}: widgets[#{index}].layout " \
                       "is missing #{missing.join(', ')}"
        end

        # The teeth. A key the schema does not know is a typo, and a silently
        # ignored typo is the failure mode this whole class exists to prevent.
        def reject_unknown!(hash, schema, where)
          return unless hash.is_a?(Hash)

          unknown = hash.keys.map(&:to_s) - schema.keys.map(&:to_s)
          unless unknown.empty?
            raise Error, "config #{path}: #{where} has unknown key(s): #{unknown.sort.join(', ')}. " \
                         "Known: #{schema.keys.sort.join(', ')}"
          end

          schema.each do |key, spec|
            next unless spec.is_a?(Hash)
            next unless hash.key?(key)

            reject_unknown!(hash[key], spec, "#{where}.#{key}")
          end
        end

        def require_present!(key)
          return unless blank?(@raw[key])

          raise Error, "config #{path}: #{key} is required"
        end

        def fetch(key) = @raw[key]
        def dig(*keys) = @raw.dig(*keys)
        def blank?(value) = value.nil? || (value.respond_to?(:empty?) && value.empty?)

        def deep_merge(base, override)
          base.merge(override) do |_key, old, new|
            old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
          end
        end
      end
    end
  end
end
