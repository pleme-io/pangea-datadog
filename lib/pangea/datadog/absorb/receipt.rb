# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'time'

module Pangea
  module Datadog
    module Absorb
      # A typed JSON receipt per the keyway standard: every run leaves a
      # machine-readable record of what it did, so a CI step or a reviewer can
      # consume the outcome without scraping stdout.
      #
      # Shape follows the live reference, akeyless-environments
      # tools/bucketsweep/outcome.go: a flat envelope (tool, command, status,
      # timestamp, target) plus a command-specific `findings` object, written to
      # <dir>/<command>-<target>-<timestamp>.json.
      #
      # Ruby, not Go, because this tool is Ruby -- the standard is the SHAPE and
      # the discipline, not the language.
      class Receipt
        PASS  = 'pass'
        FAIL  = 'fail'
        ERROR = 'error'

        # Exit codes are part of the contract: 0 pass, 1 fail, 2 error.
        # A FAIL is "the tool ran correctly and the answer is no"; an ERROR is
        # "the tool could not answer". Collapsing them would make a broken
        # config indistinguishable from a real state-match failure.
        EXIT = { PASS => 0, FAIL => 1, ERROR => 2 }.freeze

        attr_reader :tool, :command, :status, :target, :timestamp, :findings, :error

        def initialize(command:, target:, status: PASS, findings: {}, error: nil,
                       tool: 'pangea-datadog-absorb', timestamp: nil)
          @tool      = tool
          @command   = command
          @target    = target
          @status    = status
          @findings  = findings
          @error     = error
          @timestamp = timestamp || Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
        end

        def self.pass(command:, target:, findings: {})
          new(command: command, target: target, status: PASS, findings: findings)
        end

        def self.fail(command:, target:, findings: {})
          new(command: command, target: target, status: FAIL, findings: findings)
        end

        def self.error(command:, target:, message:, findings: {})
          new(command: command, target: target, status: ERROR, findings: findings, error: message)
        end

        def exit_code = EXIT.fetch(status, 2)
        def ok? = status == PASS

        def to_h
          h = {
            'tool' => tool,
            'command' => command,
            'status' => status,
            'target' => target,
            'timestamp' => timestamp,
            'findings' => findings
          }
          h['error'] = error if error
          h
        end

        def to_json(*) = JSON.pretty_generate(to_h)

        # Returns the path written, or nil when no directory was configured --
        # a receipt is a side channel and must never be the reason a run fails.
        def write(dir)
          return nil if dir.nil? || dir.to_s.empty?

          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{command}-#{sanitize(target)}-#{timestamp}.json")
          File.write(path, "#{to_json}\n")
          path
        end

        def sanitize(value)
          slug = value.to_s.gsub(%r{[^A-Za-z0-9._-]+}, '-').gsub(/\A-+|-+\z/, '')
          slug.empty? ? 'default' : slug
        end
      end
    end
  end
end
