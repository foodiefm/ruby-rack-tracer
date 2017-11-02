require 'opentracing'

module Rack
  class Tracer
    REQUEST_URI = 'REQUEST_URI'.freeze
    REQUEST_METHOD = 'REQUEST_METHOD'.freeze

    # Create a new Rack Tracer middleware.
    #
    # @param app The Rack application/middlewares stack.
    # @param tracer [OpenTracing::Tracer] A tracer to be used when start_span, and extract
    #        is called.
    # @param on_start_span [Proc, nil] A callback evaluated after a new span is created.
    # @param errors [Array<Class>] An array of error classes to be captured by the tracer
    #        as errors. Errors are **not** muted by the middleware, they're re-raised afterwards.
    # @param headers[Hash]
    def initialize(app,
                   tracer: OpenTracing.global_tracer,
                   on_start_span: nil,
                   errors: [StandardError],
                   headers: [])
      @app = app
      @tracer = tracer
      @on_start_span = on_start_span
      @errors = errors
      @headers = convert_rack_env_header_names(headers)
    end

    def call(env)
      method = env[REQUEST_METHOD]

      context = @tracer.extract(OpenTracing::FORMAT_RACK, env)

      tags = {
        'component' => 'rack',
        'span.kind' => 'server',
        'http.method' => method,
        'http.url' => env[REQUEST_URI],
        'http.uri' => env[REQUEST_URI] # For zipkin, not OT convention
      }

      @headers.each do |original, rack_header|
        tags["http.#{original}"] = env[rack_header] if env[rack_header]
      end

      span = @tracer.start_span(method,
                                child_of: context,
                                tags: tags)

      @on_start_span.call(span) if @on_start_span

      env['rack.span'] = span

      @app.call(env).tap do |status_code, _headers, _body|
        span.set_tag('http.status_code', status_code)

        if route = route_from_env(env)
          span.set_tag('route', route)
        end
      end
    rescue *@errors => e
      span.set_tag('error', true)
      span.log(event: 'error', :'error.object' => e)
      raise
    ensure
      span.finish
    end

    private

    def route_from_env(env)
      if route = env['sinatra.route']
        route.split(' ').last
      end
    end

    def convert_rack_env_header_names(headers)
      Hash[headers
           .collect { |name| [name, 'HTTP_' + name.upcase.tr('-', '_')] }]
    end
  end
end
