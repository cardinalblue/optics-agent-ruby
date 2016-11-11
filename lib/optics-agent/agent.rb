require 'optics-agent/rack-middleware'
require 'optics-agent/graphql-middleware'
require 'optics-agent/instrumenters/field'
require 'optics-agent/reporting/report_job'
require 'optics-agent/reporting/schema_job'
require 'optics-agent/reporting/query-trace'
require 'net/http'
require 'faraday'

module OpticsAgent
  class Agent
    include OpticsAgent::Reporting

    attr_reader :schema, :report_traces

    def initialize
      @query_queue = []
      @semaphone = Mutex.new

      # set defaults
      @configuration = Configuration.new
    end

    def configure(&block)
      @configuration.instance_eval(&block)

      if @configuration.schema && @schema != @configuration.schema
        instrument_schema(@configuration.schema, no_middleware: true)
      end
    end

    def disabled?
      @configuration.disable_reporting || !@configuration.api_key || !@schema
    end

    # Like instrument_schema, but intended to be called from inside a Schema.define
    # block, so we can call `schema.instrument` (we can't call when a schema is defined)
    def instrument(schema)
      debug 'adding instrumentation to schema'
      schema.instrument(:field, Instrumenters::Field.new(self))
    end

    def instrument_schema(schema, no_middleware: false)
      unless @configuration.api_key
        warn """No api_key set.
Either configure it or use the OPTICS_API_KEY environment variable.
"""
        return
      end

      @schema = schema
      debug "adding middleware to schema"
      schema.middleware << graphql_middleware unless no_middleware

      unless disabled?
        debug "spawning schema thread"
        Thread.new do
          debug "schema thread spawned"
          sleep @configuration.schema_report_delay_ms / 1000.0
          debug "running schema job"
          SchemaJob.new.perform(self)
        end
      end
    end

    # We call this method on every request to ensure that the reporting thread
    # is active in the correct process for pre-forking webservers like unicorn
    def ensure_reporting!
      unless @schema
        warn """No schema instrumented.
Use the `schema` configuration setting, or call `agent.instrument_schema`
"""
        return
      end

      unless @reporting_thread_active || disabled?
        schedule_report
        @reporting_thread_active = true
      end
    end

    def reporting_connection
      @reporting_connection ||=
        Faraday.new(:url => @configuration.endpoint_url) do |faraday|
          # XXX: allow setting adaptor in config
          faraday.adapter :net_http_persistent
        end
    end

    def schedule_report
      debug "spawning reporting thread"
      Thread.new do
        debug "reporting thread spawned"
        while true
          sleep @configuration.report_interval_ms / 1000.0
          debug "running reporting job"
          ReportJob.new.perform(self)
          debug "finished running reporting job"
        end
      end
    end

    def add_query(*args)
      @semaphone.synchronize {
        debug { "adding query to queue, queue length was #{@query_queue.length}" }
        @query_queue << args
      }
    end

    def clear_query_queue
      @semaphone.synchronize {
        debug { "clearing query queue, queue length was #{@query_queue.length}" }
        queue = @query_queue
        @query_queue = []
        queue
      }
    end

    def rack_middleware
      # We need to pass ourselves to the class we return here because
      # rack will instanciate it. (See comment at the top of RackMiddleware)
      OpticsAgent::RackMiddleware.agent = self
      OpticsAgent::RackMiddleware
    end

    def graphql_middleware
      OpticsAgent::GraphqlMiddleware.new(self)
    end

    def send_message(path, message)
      response = reporting_connection.post do |request|
        request.url path
        request.headers['x-api-key'] = @configuration.api_key
        request.headers['user-agent'] = "optics-agent-rb"

        request.body = message.class.encode(message)
        if @configuration.debug || @configuration.print_reports
          log "sending message: #{message.class.encode_json(message)}"
        end
      end

      if @configuration.debug || @configuration.print_reports
        log "got response: #{response}"
        log "response body: #{response.body}"
      end
    end

    def log(message = nil)
      message = yield unless message
      puts "optics-agent: #{message}"
    end

    def warn(message = nil)
      log message
    end

    def debug(message = nil)
      if @configuration.debug
        message = yield unless message
        log "DEBUG: #{message} <#{Process.pid} | #{Thread.current.object_id}>"
      end
    end
  end

  class Configuration
    DEFAULTS = {
      schema: nil,
      debug: false,
      disable_reporting: false,
      print_reports: false,
      report_traces: true,
      schema_report_delay_ms: 10 * 1000,
      report_interval_ms: 60 * 1000,
      api_key: ENV['OPTICS_API_KEY'],
      endpoint_url: ENV['OPTICS_ENDPOINT_URL'] || 'https://optics-report.apollodata.com'
    }

    # Allow e.g. `debug false` == `debug = false` in configuration blocks
    DEFAULTS.each_key do |key|
      define_method key, ->(*maybe_value) do
        if (maybe_value.length === 1)
          self.instance_variable_set("@#{key}", maybe_value[0])
        elsif (maybe_value.length === 0)
          self.instance_variable_get("@#{key}")
        else
          throw new ArgumentError("0 or 1 argument expected")
        end
      end
    end

    def initialize
      DEFAULTS.each { |key, value| self.send(key, value) }
    end
  end
end
