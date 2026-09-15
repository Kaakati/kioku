# frozen_string_literal: true

module Kioku
  class Doctor
    # Bounded external command execution for operator diagnostics only.
    #
    # Nothing on the hook path calls this. Hooks never invoke Docker, never run
    # tests and never launch a model; doctor is an explicit operator command
    # with its own budget.
    module Probe
      Result = Struct.new(:ran, :success, :output, keyword_init: true)

      module_function

      def run(command, timeout: 5.0)
        output = +""
        IO.popen(command, err: [:child, :out]) { |io| output << drain(io, timeout, io.pid) }
        status = $?
        Result.new(ran: true, success: status.nil? || status.success?, output: output.strip)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EPERM, Errno::ENOEXEC => e
        Result.new(ran: false, success: false, output: e.class.name)
      end

      def drain(io, timeout, pid)
        deadline = now + timeout
        buffer = +""
        loop do
          break if now > deadline && terminate(pid)

          chunk = read_available(io)
          break if chunk.nil?

          buffer << chunk
        end
        buffer
      end

      def read_available(io)
        io.read_nonblock(4_096)
      rescue IO::WaitReadable
        IO.select([io], nil, nil, 0.1)
        ""
      rescue EOFError, IOError
        nil
      end

      def terminate(pid)
        Process.kill("KILL", pid)
        true
      rescue StandardError
        true
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
