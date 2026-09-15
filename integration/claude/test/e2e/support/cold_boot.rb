# frozen_string_literal: true

require "open3"

require_relative "core_stack"

module Kioku
  module TestSupport
    # Boots the shipped compose.yml from destroyed volumes and reports what the
    # stack provisioned.
    #
    # Why this exists rather than reading the running stack: the invariant B1
    # names is a property of a COLD BOOT, and the running `kioku` project's
    # postgres_data volume has already been repaired by hand. A suite that
    # inspects the live database therefore answers "provisioned correctly" while
    # compose.yml still ships the defect, and the next `docker compose down -v`
    # brings it straight back. backend/test/integration/provisioned_database_test
    # asks the right question of the wrong instance; this asks it of an instance
    # created the way a new machine creates one.
    #
    # It runs under its own Compose PROJECT NAME, so it gets its own volumes and
    # network and cannot disturb the stack a developer is using. Neither `db` nor
    # `migrate` publishes a host port, so the two projects coexist.
    #
    # Everything is read out of the `migrate` service's own resolved environment:
    # the queries run as `psql "$DATABASE_URL"` INSIDE that container, so the
    # database under inspection is exactly the one the one-shot migration
    # prepares and `api` serves from, with no second derivation of the name.
    module ColdBoot
      PROJECT = "kioku-coldboot-test"
      INSPECT_EXTENSIONS = "SELECT extname FROM pg_extension ORDER BY extname"
      INSPECT_TABLES = <<~SQL
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name
      SQL

      Result = Struct.new(:migrate_status, :migrate_output, :extensions, :tables, keyword_init: true)

      module_function

      # One boot per process, whatever its outcome: three cases read one cold
      # boot, and a boot that could not run is reported three times rather than
      # attempted three times.
      def result
        @outcome ||= attempt
        raise @outcome if @outcome.is_a?(StandardError)

        @outcome
      end

      def attempt
        boot
      rescue StandardError => error
        error
      end

      def boot
        destroy_volumes
        status, output = run_migration
        Result.new(migrate_status: status, migrate_output: output,
                   extensions: psql(INSPECT_EXTENSIONS), tables: psql(INSPECT_TABLES))
      end

      def destroy_volumes
        compose("down", "--volumes", "--remove-orphans")
      end

      # `run --rm` reports db:prepare's own exit status, and brings `db` up first
      # because migrate depends_on it with condition: service_healthy.
      def run_migration
        stdout, stderr, status = compose("run", "--rm", "--no-TTY", "migrate")
        [status.exitstatus, "#{stdout}#{stderr}"]
      end

      def psql(sql)
        script = %(psql "$DATABASE_URL" --tuples-only --no-align --command #{shell_quote(sql)})
        stdout, _stderr, status = compose("run", "--rm", "--no-TTY", "--entrypoint", "sh",
                                          "migrate", "-c", script)
        return [] unless status.success?

        stdout.lines.map(&:strip).reject(&:empty?)
      end

      def shell_quote(value)
        "'#{value.gsub("'", "'\\\\''")}'"
      end

      def compose(*arguments)
        Open3.capture3("docker", "compose", "--project-name", PROJECT, *arguments,
                       chdir: CoreStack::REPO_ROOT)
      rescue Errno::ENOENT
        raise "the docker CLI is not available, so the stack's cold boot cannot be exercised"
      end
    end
  end
end

# The project this suite boots is its own, so tearing it down cannot touch the
# stack a developer is running. A teardown that cannot run must not replace the
# run's result with its own error.
Minitest.after_run do
  Kioku::TestSupport::ColdBoot.destroy_volumes
rescue StandardError => error
  warn("could not remove the #{Kioku::TestSupport::ColdBoot::PROJECT} project: #{error.message}")
end
