# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Pangea
  module Datadog
    module Absorb
      # Read-only Datadog API client.
      #
      # Absorb never writes to Datadog. The estate is the source of truth until
      # the generated code is proven to state-match it; only then does anything
      # apply. Every method here is a GET.
      class Client
        DEFAULT_SITE = 'datadoghq.com'

        # The fleet deploys both keys via sops-nix at this path.
        CREDENTIAL_DIR = File.join(Dir.home, '.config', 'datadog')

        Error = Class.new(StandardError)

        attr_reader :site

        def initialize(api_key:, app_key:, site: DEFAULT_SITE)
          raise Error, 'api_key is required' if api_key.nil? || api_key.empty?
          raise Error, 'app_key is required' if app_key.nil? || app_key.empty?

          @api_key = api_key
          @app_key = app_key
          @site    = site
        end

        # Build a client from typed config.
        #
        # Two credential sources, and sops is the default because it is what the
        # fleet actually runs. `Pangea::Secrets.resolve` (pangea-core) already
        # implements the whole chain -- env var, then the sops-nix pre-decrypted
        # file, then a `sops -d` extraction -- so this reuses it rather than
        # reimplementing any part of it.
        #
        # The `files` source stays for a machine with no sops at all. Note that
        # ~/.config/datadog/<account>/api-key is itself a symlink into
        # ~/.config/sops-nix/secrets/, so even that path is reading sops output;
        # it just hardcodes the location instead of asking the resolver.
        def self.from_config(config, site: nil)
          resolved_site = site || config.site
          return for_account(config.account, site: resolved_site) unless config.sops?

          require 'pangea/secrets'
          Pangea::Secrets.configure(
            sops_file: config.sops_file,
            sops_nix_dir: config.sops_nix_dir
          )
          new(
            api_key: Pangea::Secrets.resolve(config.api_key_secret),
            app_key: Pangea::Secrets.resolve(config.app_key_secret),
            site: resolved_site
          )
        rescue LoadError
          raise Error, 'credentials.source is sops but pangea-core is unavailable; ' \
                       'add pangea-core or set credentials.source: files'
        rescue StandardError => e
          raise Error, "sops resolution failed for #{config.api_key_secret} / " \
                       "#{config.app_key_secret}: #{e.message}"
        end

        # Resolve credentials from the fleet secret layout, falling back to env.
        #
        #   ~/.config/datadog/<account>/api-key
        #   ~/.config/datadog/<account>/app-key
        def self.for_account(account, site: DEFAULT_SITE)
          dir = File.join(CREDENTIAL_DIR, account)
          api = read_secret(File.join(dir, 'api-key'), 'DD_API_KEY')
          app = read_secret(File.join(dir, 'app-key'), 'DD_APP_KEY')
          new(api_key: api, app_key: app, site: site)
        end

        def self.read_secret(path, env_var)
          return File.read(path).strip if File.readable?(path)

          value = ENV[env_var]
          return value.strip if value && !value.empty?

          raise Error, "no credential at #{path} and #{env_var} is unset"
        end

        # v1 returns every monitor in one page when page_size is omitted, but the
        # response is large enough that paging keeps memory predictable.
        def monitors
          page  = 0
          size  = 200
          all   = []
          loop do
            batch = get_json("/api/v1/monitor?page_size=#{size}&page=#{page}")
            break if batch.nil? || batch.empty?

            all.concat(batch)
            break if batch.size < size

            page += 1
          end
          all
        end

        # The list endpoint omits widgets, so each dashboard is fetched whole.
        def dashboard_summaries
          body = get_json('/api/v1/dashboard')
          body.fetch('dashboards', [])
        end

        def dashboard(id)
          get_json("/api/v1/dashboard/#{id}")
        end

        def service_level_objectives
          body = get_json('/api/v1/slo?limit=1000')
          body.fetch('data', [])
        end

        def downtimes
          get_json('/api/v1/downtime')
        end

        # The logs configuration layer. Pipelines come back as a bare array; the
        # v2 metrics endpoint wraps in `data`; indexes wrap in `indexes`.
        def logs_pipelines
          get_json('/api/v1/logs/config/pipelines')
        end

        def logs_metrics
          get_json('/api/v2/logs/config/metrics').fetch('data', [])
        end

        def logs_indexes
          get_json('/api/v1/logs/config/indexes').fetch('indexes', [])
        end

        # The account layer: who exists, what they may do, and which
        # dashboards/traces/apps are grouped how. None of it credential-bearing
        # -- the RUM list response carries `api_key_id` (a reference) but no
        # `client_token`, which was screened before this was added.
        def powerpacks
          get_json('/api/v2/powerpacks').fetch('data', [])
        end

        def teams
          get_json('/api/v2/team').fetch('data', [])
        end

        def roles
          get_json('/api/v2/roles').fetch('data', [])
        end

        # Metric names Datadog has seen report since `from`. This is the estate
        # speaking rather than an inference from names, which is what makes it
        # safe to call a monitor dead.
        def active_metrics(from:)
          get_json("/api/v1/metrics?from=#{from.to_i}").fetch('metrics', [])
        end

        # The account's permission CATALOG, not a permission grant. Read-only,
        # and the only thing that says which permissions Datadog marks
        # `restricted` -- a role's own payload lists permission ids and nothing
        # about them. Measured on this estate: 342 permissions, 10 restricted.
        def permissions
          get_json('/api/v2/permissions').fetch('data', [])
        end

        def rum_applications
          get_json('/api/v2/rum/applications').fetch('data', [])
        end

        def apm_retention_filters
          get_json('/api/v2/apm/config/retention-filters').fetch('data', [])
        end

        # A list's own record reports `dashboards: null`; the membership needs a
        # second call, and membership is the entire point of the resource.
        def dashboard_lists
          get_json('/api/v1/dashboard/lists/manual').fetch('dashboard_lists', []).map do |list|
            list.merge('dashboards' => dashboard_list_items(list.fetch('id')))
          end
        end

        def dashboard_list_items(id)
          get_json("/api/v2/dashboard/lists/manual/#{id}/dashboards").fetch('dashboards', [])
        end

        # Returns [code, body] and never raises on a non-2xx. get_json raises,
        # which is right for a capture (a failed fetch means an incomplete
        # capture) and wrong for a census, where "the key cannot read this" is
        # itself the finding.
        def probe(path)
          uri = URI("https://api.#{@site}#{path}")
          req = Net::HTTP::Get.new(uri)
          req['DD-API-KEY']         = @api_key
          req['DD-APPLICATION-KEY'] = @app_key
          req['Accept']             = 'application/json'

          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 60) do |http|
            http.request(req)
          end
          [res.code.to_i, res.body]
        end

        private

        def get_json(path)
          uri = URI("https://api.#{@site}#{path}")
          req = Net::HTTP::Get.new(uri)
          req['DD-API-KEY']         = @api_key
          req['DD-APPLICATION-KEY'] = @app_key
          req['Accept']             = 'application/json'

          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 60) do |http|
            http.request(req)
          end

          unless res.is_a?(Net::HTTPSuccess)
            raise Error, "GET #{path} returned #{res.code}: #{res.body.to_s[0, 200]}"
          end

          JSON.parse(res.body)
        end
      end
    end
  end
end
