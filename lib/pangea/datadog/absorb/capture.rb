# frozen_string_literal: true

require 'json'
require 'fileutils'

module Pangea
  module Datadog
    module Absorb
      # Rung 1 of the staircase: absorb the live estate to disk, losslessly.
      #
      # The capture is the reference the generated code is later proven against,
      # so it stores the API payload verbatim. Nothing is dropped here; the
      # projection happens in Normalize, against this file, and can therefore be
      # re-run and re-argued without touching Datadog again.
      class Capture
        MANIFEST = 'manifest.json'

        # A FILE at the capture root, deliberately not a kind directory. It is a
        # reference catalog -- the provider has no `datadog_permission` resource,
        # so there is nothing to emit from it -- and verify's coverage check
        # enumerates DIRECTORIES, so a kind directory here would read as a
        # permanent uncovered gap.
        PERMISSIONS = 'permissions.json'

        attr_reader :root

        def initialize(root)
          @root = root
        end

        DEFAULT_KINDS = %i[monitors dashboards slos downtimes
                           logs_pipelines logs_metrics logs_indexes
                           teams roles rum_applications apm_retention_filters
                           dashboard_lists powerpacks].freeze

        # kind => the reader on Client and the field its id lives in. These
        # kinds need none of the per-object follow-up fetches monitors and
        # dashboards do, so one table replaces five near-identical blocks.
        SIMPLE_KINDS = {
          teams: [:teams, 'id'],
          roles: [:roles, 'id'],
          rum_applications: [:rum_applications, 'id'],
          apm_retention_filters: [:apm_retention_filters, 'id'],
          dashboard_lists: [:dashboard_lists, 'id'],
          powerpacks: [:powerpacks, 'id']
        }.freeze

        def self.run(client:, root:, kinds: DEFAULT_KINDS, progress: nil)
          capture = new(root)
          capture.prepare
          counts = {}

          if kinds.include?(:monitors)
            monitors = client.monitors
            monitors.each { |m| capture.write(:monitors, m.fetch('id').to_s, m) }
            counts[:monitors] = monitors.size
            progress&.call(:monitors, monitors.size)
          end

          if kinds.include?(:dashboards)
            summaries = client.dashboard_summaries
            summaries.each_with_index do |summary, i|
              id = summary.fetch('id')
              capture.write(:dashboards, id, client.dashboard(id))
              progress&.call(:dashboards, i + 1)
            end
            counts[:dashboards] = summaries.size
          end

          if kinds.include?(:slos)
            slos = client.service_level_objectives
            slos.each { |s| capture.write(:slos, s.fetch('id').to_s, s) }
            counts[:slos] = slos.size
            progress&.call(:slos, slos.size)
          end

          if kinds.include?(:downtimes)
            downtimes = client.downtimes
            downtimes.each { |d| capture.write(:downtimes, d.fetch('id').to_s, d) }
            counts[:downtimes] = downtimes.size
            progress&.call(:downtimes, downtimes.size)
          end

          # The logs configuration layer. A pipeline's id is opaque; a metric's
          # id IS its name; an index has no id at all and is addressed by name,
          # which is also how terraform imports it.
          if kinds.include?(:logs_pipelines)
            pipelines = client.logs_pipelines
            pipelines.each { |p| capture.write(:logs_pipelines, p.fetch('id'), p) }
            counts[:logs_pipelines] = pipelines.size
            progress&.call(:logs_pipelines, pipelines.size)
          end

          if kinds.include?(:logs_metrics)
            metrics = client.logs_metrics
            metrics.each { |m| capture.write(:logs_metrics, m.fetch('id'), m) }
            counts[:logs_metrics] = metrics.size
            progress&.call(:logs_metrics, metrics.size)
          end

          if kinds.include?(:logs_indexes)
            indexes = client.logs_indexes
            indexes.each { |i| capture.write(:logs_indexes, i.fetch('name'), i) }
            counts[:logs_indexes] = indexes.size
            progress&.call(:logs_indexes, indexes.size)
          end

          SIMPLE_KINDS.each do |kind, (reader, id_field)|
            next unless kinds.include?(kind)

            items = client.public_send(reader)
            items.each { |i| capture.write(kind, i.fetch(id_field), i) }
            counts[kind] = items.size
            progress&.call(kind, items.size)
          end

          # Roles are the only consumer, so it is fetched only when they are.
          if kinds.include?(:roles)
            catalog = client.permissions
            capture.write_permissions(catalog)
            progress&.call(:permissions, catalog.size)
          end

          capture.write_manifest(counts, site: client.site)
          counts
        end

        # Every kind that could hold objects. `empty?` asks whether the capture
        # holds ANY of them, which is what tells a gate that it has nothing to
        # check versus nothing to say.
        def empty?
          DEFAULT_KINDS.none? { |kind| Dir.exist?(dir(kind)) && !ids(kind).empty? }
        end

        def exist? = Dir.exist?(root)

        def prepare
          FileUtils.mkdir_p(root)
        end

        def dir(kind)
          File.join(root, kind.to_s)
        end

        def write(kind, id, payload)
          FileUtils.mkdir_p(dir(kind))
          File.write(path(kind, id), "#{JSON.pretty_generate(payload)}\n")
        end

        def path(kind, id)
          File.join(dir(kind), "#{sanitize(id)}.json")
        end

        def read(kind, id)
          JSON.parse(File.read(path(kind, id)))
        end

        # A PROVIDER-NORMALIZED body, recorded alongside the raw API payload by
        # `reconcile`. It exists because the Datadog provider's read and plan
        # normalizations disagree, so for some objects no transformation of the
        # API payload can produce a body that plans clean -- only the provider's
        # own post-import body can.
        #
        # Storing it in the CAPTURE rather than in the emitted code is what keeps
        # `verify`'s contract intact: the comparison stays code-vs-estate, and
        # the provider's view simply becomes part of the recorded estate.
        def normalized_path(kind, id)
          File.join(root, "#{kind}_normalized", "#{sanitize(id)}.json")
        end

        def normalized?(kind, id) = File.exist?(normalized_path(kind, id))

        def normalized(kind, id)
          return nil unless normalized?(kind, id)

          JSON.parse(File.read(normalized_path(kind, id)))
        end

        def write_normalized(kind, id, body)
          FileUtils.mkdir_p(File.dirname(normalized_path(kind, id)))
          File.write(normalized_path(kind, id), "#{JSON.pretty_generate(body)}\n")
        end

        def ids(kind)
          Dir.glob(File.join(dir(kind), '*.json')).map { |f| File.basename(f, '.json') }.sort
        end

        def each(kind)
          return enum_for(:each, kind) unless block_given?

          ids(kind).each { |id| yield(id, JSON.parse(File.read(path(kind, id)))) }
        end

        # MERGES. A partial capture (`--kinds logs_metrics`) must not erase the
        # counts of the kinds it did not fetch, or the manifest would claim the
        # estate is whatever the last narrow run happened to touch.
        def write_permissions(catalog)
          File.write(File.join(root, PERMISSIONS), JSON.pretty_generate(catalog))
        end

        def permissions_captured?
          File.exist?(File.join(root, PERMISSIONS))
        end

        # The ids Datadog marks `restricted` -- the default read permissions it
        # grants every role implicitly. The provider REFUSES a plan that names
        # one, so emit has to drop them.
        def restricted_permissions
          return nil unless permissions_captured?
          return @restricted_permissions if defined?(@restricted_permissions)

          @restricted_permissions =
            JSON.parse(File.read(File.join(root, PERMISSIONS)))
               .select { |p| p.dig('attributes', 'restricted') }
               .map { |p| p['id'].to_s }
               .to_set
        end

        def write_manifest(counts, site:)
          merged = manifest.fetch('counts', {}).merge(counts.transform_keys(&:to_s))
          File.write(
            File.join(root, MANIFEST),
            "#{JSON.pretty_generate('site' => site, 'counts' => merged.sort.to_h)}\n"
          )
        end

        def manifest
          path = File.join(root, MANIFEST)
          File.exist?(path) ? JSON.parse(File.read(path)) : {}
        end

        # Datadog dashboard ids are already filesystem-safe, but monitor ids are
        # integers and a hand-placed fixture could be anything.
        def sanitize(id)
          id.to_s.gsub(%r{[^A-Za-z0-9._-]}, '_')
        end
      end
    end
  end
end
