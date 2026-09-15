# frozen_string_literal: true

module Kioku
  module TestSupport
    # Runs a one-shot host entry point (contextctl) with stdout, stderr and stdin
    # kept strictly separate, and measures wall-clock time against the hook budget
    # [plan §3 "stdout is event-specific output; diagnostics use stderr";
    #  research Appendix B one-second hook timeout].
    class HostCommand
      Result = Struct.new(:stdout, :stderr, :status, :elapsed, :stdin_outcome, keyword_init: true) do
        def exited?
          !status.nil?
        end

        def exit_code
          status&.exitstatus
        end
      end

      def self.run(name, *args, stdin_data: nil, env: {}, timeout: 5.0)
        stream(name, *args, env: env, timeout: timeout) do |stdin|
          stdin.write(stdin_data) unless stdin_data.nil?
          :consumed
        end
      end

      # Yields the child's stdin so a test can decide how much to write; the block
      # returns the outcome symbol. EPIPE is reported as :refused.
      def self.stream(name, *args, env: {}, timeout: 5.0, &block)
        path = StdioServer.require_binary!(name)
        started = Clock.monotonic
        stdin, out, err, wait = Open3.popen3(StdioServer.process_env(env), RbConfig.ruby, path, *args)
        collector = Collector.new(stdin, out, err)
        collector.start(&block)
        status = wait_for_exit(wait, timeout)
        collector.finish
        Result.new(stdout: collector.stdout, stderr: collector.stderr, status: status,
                   elapsed: Clock.monotonic - started, stdin_outcome: collector.stdin_outcome)
      end

      def self.wait_for_exit(wait, timeout)
        return wait.value if wait.join(timeout)

        begin
          Process.kill("KILL", wait.pid)
        rescue Errno::ESRCH, Errno::EPERM, RangeError
          nil
        end
        wait.join(2.0)
        nil
      end

      # Drains both output streams on their own threads so a chatty child can never
      # deadlock a test that is still writing to its stdin.
      class Collector
        attr_reader :stdout, :stderr, :stdin_outcome

        def initialize(stdin, out, err)
          @stdin = stdin
          @out = out
          @err = err
          @stdout = +""
          @stderr = +""
          @stdin_outcome = :consumed
        end

        def start(&block)
          @out_thread = Thread.new { @stdout << @out.read.to_s }
          @err_thread = Thread.new { @stderr << @err.read.to_s }
          @in_thread = Thread.new { write_stdin(&block) }
        end

        def finish
          @in_thread.join(2.0) || (@stdin_outcome = :blocked)
          @in_thread.kill
          @out_thread.join(2.0)
          @err_thread.join(2.0)
        end

        private

        def write_stdin
          @stdin_outcome = yield(@stdin)
        rescue Errno::EPIPE, Errno::EINVAL, IOError
          @stdin_outcome = :refused
        ensure
          begin
            @stdin.close unless @stdin.closed?
          rescue IOError, Errno::EPIPE, Errno::EINVAL
            nil
          end
        end
      end
    end
  end
end
