require 'pry'
require 'slop'
require 'drab'
require 'readline'
require 'open3'

module PrayRemote
  DefaultHost = "127.0.0.1"
  DefaultPort = 9876

  def self.kwargs(args)
    if args.last.is_a?(Hash)
      args.pop
    else
      {}
    end
  end

  class StdoeWrapper
    include DRab::DRabUndumped

    class_variable_set(:@@drab_whitelist, [
      "respond_to?", "write", "print", "eof?", "puts", "printf", "<<", "tty?",
      "to_s", "nil?", "flush"
    ])

    def initialize(o)
      @stdoe = o
    end

    def respond_to?(*args)
      case args[0]
      when :_dump
        true
      when :marshal_dump
        false
      else
        @stdoe.respond_to?(*args)
      end
    end

    def flush
      @stdoe.flush
    end

    def write(*args)
      @stdoe.write(*args)
    end

    def print(*args)
      @stdoe.print(*args)
    end

    def eof?
      @stdoe.eof?
    end

    def puts(*lines)
      @stdoe.puts(*lines)
    end

    def printf(*args)
      @stdoe.printf(*args)
    end

    def <<(data)
      @stdoe << data
      self
    end

    # Some versions of Pry expect $stdout or its output objects to respond to
    # this message.
    def tty?
      false
    end

  end

  class ThreadWrapper
    include DRab::DRabUndumped

    class_variable_set(:@@drab_whitelist, [
      "run", "nil?"
    ])

    def initialize(o)
      @thread = o
    end

    def run
      ThreadWrapper.new(@thread.run)
    end

    def nil?
      @thread.nil?
    end
  end

  # A class to represent an input object created from DRab. This is used because
  # Pry checks for arity to know if a prompt should be passed to the object.
  #
  # @attr [#readline] input Object to proxy
  InputProxy = Struct.new :input do
    include DRab::DRabUndumped

    class_variable_set(:@@drab_whitelist, [
      "readline", "completion_proc=", "readline_arity",
    ])

    # Reads a line from the input
    def readline(prompt)
      arity = readline_arity
      case
      when arity == 1 then
        input.readline(prompt)
      when arity < 0 then
        input.readline(prompt)
      when arity == 0 then
        input.readline
      end
    end

    def completion_proc=(val)
      input.completion_proc = val
    end

    def readline_arity
      input.readline_arity
    rescue NameError
      0
    end
  end

  # Class used to wrap inputs so that they can be sent through DRab.
  #
  # This is to ensure the input is used locally and not reconstructed on the
  # server by DRab.
  class IOUndumpedProxy
    include DRab::DRabUndumped

    class_variable_set(:@@drab_whitelist, [
      "to_s", "completion_proc=", "completion_proc", "puts", "print", "printf",
      "write", "<<", "tty?", "initialize", "method", "readline", "readline_arity"
    ])

    def initialize(obj)
      @obj = obj
      @arity = obj.method(:readline).arity
    end

    def completion_proc=(val)
      if @obj.respond_to? :completion_proc=
        @obj.completion_proc = proc { |*args, &block| val.call(*args, &block) }
      end
    end

    def completion_proc
      @obj.completion_proc if @obj.respond_to? :completion_proc
    end

    def readline_arity
      @arity
    end

    def readline(prompt)
      if Readline == @obj
        @obj.readline(prompt, true)
      elsif @arity == 1
        @obj.readline(prompt)
      else
        $stdout.print prompt
        @obj.readline
      end
    end

    def puts(*lines)
      @obj.puts(*lines)
    end

    def print(*objs)
      @obj.print(*objs)
    end

    def printf(*args)
      @obj.printf(*args)
    end

    def write(data)
      @obj.write data
    end

    def <<(data)
      @obj << data
      self
    end

    # Some versions of Pry expect $stdout or its output objects to respond to
    # this message.
    def tty?
      false
    end
  end

  # Ensure that system (shell command) output is redirected for remote session.
  System = proc do |output, cmd, _|
    status = nil
    Open3.popen3 cmd do |stdin, stdout, stderr, wait_thr|
      stdin.close # Send EOF to the process

      until stdout.eof? and stderr.eof?
        if res = IO.select([stdout, stderr])
          res[0].each do |io|
            next if io.eof?
            output.write io.read_nonblock(1024)
          end
        end
      end

      status = wait_thr.value
    end

    unless status.success?
      output.puts "Error while executing command: #{cmd}"
    end
  end

  # A client is used to retrieve information from the client program.
  Client = Struct.new(:input, :output, :thread, :stdout, :stderr,
                      :editor, :mypry) do
    include DRab::DRabUndumped

    class_variable_set(:@@drab_whitelist, [
      "wait", "kill", "input_proxy",
      "input=", "output=", "thread=", "stdout=", "stderr=",
      "input", "output", "thread", "stdout", "stderr", "mypry", "mypry="
    ])

    # Waits until both an input and output are set
    def wait
      sleep 0.01 until input and output and thread
    end

    # Tells the client the session is terminated
    def kill
      thread.run if not thread.nil?
    end

    # @return [InputProxy] Proxy for the input
    def input_proxy
      InputProxy.new input
    end
  end

  class Server
    def self.run(object, *args)
      options = PrayRemote.kwargs(args)
      new(object, options).run
    end

    def initialize(object, *args)
      options = PrayRemote.kwargs(args)

      @host    = options[:host] || DefaultHost
      @port    = options[:port] || DefaultPort

      @unix = options[:unix] || false
      @secret = ""
      if options[:secret] != nil
        @secret = "?secret=" + options[:secret]
      end

      if @unix == false
        @uri = "druby://#{@host}:#{@port}#{@secret}"
        @unix = ""
      else
        @uri = "drabunix:#{@unix}"
      end

      @object  = object
      @options = options

      @client = PrayRemote::Client.new
      DRab.start_service @uri, @client
    end

    # Code that has to be called for Pry-remote to work properly
    def setup
      if @client.stdout.nil?
        @client.stdout = $stdout
      end
      if @client.stderr.nil?
        @client.stderr = $stderr
      end
      @hooks = Pry::Hooks.new

      @hooks.add_hook :before_eval, :pry_remote_capture do
        capture_output
      end

      @hooks.add_hook :after_eval, :pry_remote_uncapture do
        uncapture_output
      end

      @hooks.add_hook :before_session, :pry_instance_get do |output, bind, mypry|
        #puts mypry.class
        #puts mypry.methods
        @client.mypry = mypry
      end

      # Before Pry starts, save the pager config.
      # We want to disable this because the pager won't do anything useful in
      # this case (it will run on the server).
      Pry.config.pager, @old_pager = false, Pry.config.pager

      # As above, but for system config
      Pry.config.system, @old_system = PrayRemote::System, Pry.config.system

      Pry.config.editor, @old_editor = nil, Pry.config.editor
      #binding.pry # for testing attacks on clients
    end

    # Code that has to be called after setup to return to the initial state
    def teardown
      # Reset config
      Pry.config.editor = @old_editor
      Pry.config.pager  = @old_pager
      Pry.config.system = @old_system

      STDOUT.puts "[pry-remote] Remote session terminated"

      begin
        @client.kill
      rescue DRab::DRabConnError
        STDOUT.puts "[pry-remote] Continuing to stop service"
      ensure
        STDOUT.puts "[pry-remote] Ensure stop service"
        DRab.stop_service
      end
    end

    # Captures $stdout and $stderr if so requested by the client.
    def capture_output
      $stdout = @client.stdout
      $stderr = @client.stderr
    end

    # Resets $stdout and $stderr to their previous values.
    def uncapture_output
      $stdout = STDOUT
      $stderr = STDOUT
    end

    # Actually runs pry-remote
    def run
      STDOUT.puts "[pry-remote] Waiting for client on #{uri}"
      @client.wait

      STDOUT.puts "[pry-remote] Client received, starting remote session"
      setup

      Pry.start(@object, @options.merge(:input => client.input_proxy,
                                        :output => client.output,
                                        :hooks => @hooks))
    ensure
      teardown
    end

    # @return Object to enter into
    attr_reader :object

    # @return [PryServer::Client] Client connecting to the pry-remote server
    attr_reader :client

    # @return [String] Host of the server
    attr_reader :host

    # @return [Integer] Port of the server
    attr_reader :port

    # @return [String] Unix domain socket path of the server
    attr_reader :unix

    # @return [String] URI for DRab
    attr_reader :uri

  end

  # Parses arguments and allows to start the client.
  class CLI
    # @return [String] Host of the server
    attr_reader :host

    # @return [Integer] Port of the server
    attr_reader :port

    # @return [String] Unix domain socket path of the server
    attr_reader :unix

    # @return [String] URI for DRab
    attr_reader :uri

    # @return [String] Bind for local DRab server
    attr_reader :bind

    attr_reader :wait
    attr_reader :persist
    attr_reader :capture
    alias wait? wait
    alias persist? persist
    alias capture? capture
  
    def initialize(args = ARGV)
      params = Slop.parse args, :help => true do
        banner "#$PROGRAM_NAME [OPTIONS]"

        on :s, :server=, "Host of the server (#{DefaultHost})", :argument => true,
           :default => DefaultHost
        on :p, :port=, "Port of the server (#{DefaultPort})", :argument => true,
           :as => Integer, :default => DefaultPort
        on :w, :wait, "Wait for the pry server to come up",
           :default => false
        on :r, :persist, "Persist the client to wait for the pry server to come up each time",
           :default => false
        on :c, :capture=, "Captures $stdout and $stderr from the server (true)", :argument => true,
           :default => true
        on :f, "Disables loading of .pryrc and its plugins, requires, and command history "
        on :b, :bind=, "Local Drb bind (IP open to server and random port by default, or a Unix domain socket path)"
        on :z, :bind_proto=, "Protocol for bind to override connection-based default (tcp or unix)"
        on :u, :unix=, "Unix domain socket path of the server"
        on :k, :secret=, "Shared secret for authenticating to the server (TCP only)"
      end

      exit if params.help?

      @host = params[:server]
      @port = params[:port]

      @bind = params[:bind]
      @bind_proto = params[:bind_proto]

      @unix = params[:unix]
      @secret = ""
      if params[:secret] != nil
        #@secret = "?secret=" + params[:secret]
        @secret = params[:secret]
      end

      if @bind_proto == nil
        if @unix == nil
          @bind_proto = "druby://"
        else
          @bind_proto = "drabunix:"
        end
      else
        if @bind_proto == "tcp"
        elsif @bind_proto == "unix"
        else
          STDOUT.puts "[pry-remote] invalid bind protocol"
          exit
        end
      end

      if @unix == nil
        @uri = "druby://#{@host}:#{@port}"
        #@uri = "druby://#{@host}:#{@port}#{@secret}"
        @unix = ""
      else
        if @bind == nil
          STDOUT.puts "[pry-remote] bind not supplied for Unix domain socket connection"
          exit
        end
        @uri = "drabunix:#{@unix}"
      end

      @wait = params[:wait]
      @persist = params[:persist]
      @capture = params[:capture] === "false" ? false : params[:capture]

      Pry.initial_session_setup unless params[:f]
    end

  
    def run
      while true
        connect
        break unless persist?
      end
    end

    # Connects to the server
    #
    # @param [IO] input  Object holding input for pry-remote
    # @param [IO] output Object pry-debug will send its output to
    def connect(input = Pry.config.input, output = Pry.config.output)
      secret_str = @secret != "" ? "?secret=#{@secret}" : ""

      if bind == false
        local_ip = UDPSocket.open {|s| s.connect(@host, 1); s.addr.last}
        DRab.start_service "druby://#{local_ip}:0#{secret_str}"
      else
        if @bind_proto == "tcp"
          DRab.start_service "druby://#{bind}#{secret_str}"
        else
          DRab.start_service "drabunix:#{bind}#{secret_str}"
        end
      end
      $client = DRabObject.new(nil, uri)

      begin
        $client.input  = IOUndumpedProxy.new(input)
        $client.output = IOUndumpedProxy.new(output)
      rescue DRab::DRabConnError => ex
        if wait? || persist?
          sleep 1
          retry
        else
          raise ex
        end
      end

      if capture?
        $client.stdout = StdoeWrapper.new($stdout)
        $client.stderr = StdoeWrapper.new($stderr)
      end

      $client.thread = ThreadWrapper.new(Thread.current)

      # solved by using own object mapper, leaving this here though for future reference
      #GC.disable # spooky stuff happens causing the client to garbage collect the StdoeWrappers


      # currently not able to properly pass :control_c/emulate it
      # just preventing accidental close for now
      def set_trap
        Signal.trap("INT")  do
          begin
            #Thread.new {
            #  begin
            #    puts $client.mypry.repl.to_s
            #    $client.mypry.repl.output.puts ""
            #    $client.mypry.reset_eval_string
            #  rescue Exception => e
            #    puts e
            #    puts e.backtrace
            #  end
            #}
            Thread.new {
              begin
                $client.mypry.to_s
              rescue Exception => e
                exit(1)
              end
            }
          rescue Exception => e
            puts e
            puts e.backtrace
          end
          set_trap
        end
      end

      begin
        set_trap
        sleep
      ensure
        DRab.stop_service
      end
    end

  end
end

class Object
  # Starts a remote Pry session
  #
  # @param [String] host Host of the server (legacy)
  # @param [Integer] port Port of the server (legacy)
  # @param [Hash] options Options to be passed to Pry.start
  def remote_pry(*args)
    options = PrayRemote.kwargs(args)
    if args.length == 3
      options[:secret] = args.pop
    end
    if args.length == 2
      options[:port] = args.pop
    end
    if args.length == 1
      options[:host] = args.pop
    end
    PrayRemote::Server.new(self, options).run
  end

  # a handy alias as many people may think the method is named after the gem
  # (pry-remote)
  alias pry_remote remote_pry
end
